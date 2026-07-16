//
//  CaptureController.swift
//  ClosetScanner
//
//  Owns the ARSession. Capture = accumulate high-confidence LiDAR depth pixels
//  from a reticle window over ~40 frames, unproject to world space, and fit a
//  robust plane. Dimensions are plane-to-plane gaps, so boxes/cabinets hiding
//  the corners never matter. Once the six core planes exist we render an
//  opaque clean shell at the fitted planes — the closet looks empty on screen.
//

import ARKit
import RealityKit
import SwiftUI
import Combine
import AVFoundation

struct Measurement: Identifiable {
    let name: String
    let meters: Double
    /// Displayed uncertainty: standard error ⊕ world-scale error, floored at 1/32″.
    let plusMinus: Double
    let angleDegrees: Double
    /// ARKit plane-anchor estimate minus ours (independent cross-check), if available.
    let crossCheckDelta: Double?
    var id: String { name }
}

struct CapturedSurface {
    let label: SurfaceLabel
    let fit: PlaneFit
    let crossNormal: SIMD3<Double>?
    let crossPoint: SIMD3<Double>?
    let warning: String?
}

final class CaptureController: NSObject, ObservableObject, ARSessionDelegate {
    static let lidarAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)

    let captureOrder: [SurfaceLabel]

    @Published var target: SurfaceLabel
    @Published private(set) var surfaces: [SurfaceLabel: CapturedSurface] = [:]
    @Published private(set) var measurements: [Measurement] = []
    @Published private(set) var captureProgress: Double?
    @Published private(set) var status = "Starting camera…"
    @Published private(set) var trackingNormal = false
    @Published var torchOn = false { didSet { setTorch(torchOn) } }
    @Published private(set) var calibration = UserDefaults.standard.object(forKey: "calibrationScale") as? Double ?? 1.0

    var shellVisible: Bool { SurfaceLabel.coreOrder.allSatisfy { surfaces[$0] != nil } }
    var allCaptured: Bool { captureOrder.allSatisfy { surfaces[$0] != nil } }

    var stepText: String {
        let step = (captureOrder.firstIndex(of: target) ?? 0) + 1
        return "Step \(step) of \(captureOrder.count) · \(target.phase)"
    }

    init(hasSoffit: Bool) {
        let order = SurfaceLabel.captureOrder(hasSoffit: hasSoffit)
        captureOrder = order
        target = order[0]
        super.init()
    }

    private weak var arView: ARView?
    private var capturing: SurfaceLabel?
    private var framesLeft = 0
    private var buffer: [SIMD3<Float>] = []
    private var crossHit: (normal: SIMD3<Double>, point: SIMD3<Double>)?
    private let totalFrames = 40

    // MARK: Session

    func attach(_ view: ARView) {
        arView = view
        view.automaticallyConfigureSession = false
        view.session.delegate = self
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        view.session.run(config)
    }

    func stop() {
        capturing = nil
        captureProgress = nil
        buffer.removeAll()
        torchOn = false
        arView?.session.pause()
        arView = nil
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // ARSession delivers delegate calls on the main thread.
        MainActor.assumeIsolated { handleFrame(frame) }
    }

    private func handleFrame(_ frame: ARFrame) {
        var isNormal = false
        if case .normal = frame.camera.trackingState { isNormal = true }
        if isNormal != trackingNormal { trackingNormal = isNormal }

        guard let label = capturing else {
            let s = isNormal ? idleStatus() : trackingStatus(frame.camera.trackingState)
            if s != status { status = s }
            return
        }
        guard isNormal else {
            cancelCapture("Tracking lost — hold steadier and retry")
            return
        }
        extractPoints(frame: frame, fraction: label.windowFraction)
        framesLeft -= 1
        captureProgress = 1 - Double(framesLeft) / Double(totalFrames)
        if framesLeft <= 0 { finishCapture(label, camera: frame.camera) }
    }

    private func idleStatus() -> String {
        if allCaptured {
            return "All surfaces captured — open the 3D view, or tap a measurement to calibrate"
        }
        return target.hint
    }

    private func trackingStatus(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .limited(.initializing): "Move the phone slowly to start tracking…"
        case .limited(.excessiveMotion): "Too fast — move slower"
        case .limited(.insufficientFeatures): "Too dark or blank — try the torch"
        case .limited(.relocalizing): "Relocalizing — pan around slowly"
        case .notAvailable: "Tracking unavailable"
        default: "Ready"
        }
    }

    // MARK: Capture

    func beginCapture() {
        guard capturing == nil, trackingNormal, let arView else { return }
        guard Self.lidarAvailable else {
            status = "This device has no LiDAR — cannot capture"
            return
        }
        // Independent cross-check: what does ARKit's own plane detection say?
        crossHit = nil
        let center = CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        if let hit = arView.raycast(from: center, allowing: .existingPlaneGeometry, alignment: .any).first {
            let t = hit.worldTransform
            let n = simd_normalize(SIMD3<Double>(Double(t.columns.1.x), Double(t.columns.1.y), Double(t.columns.1.z)))
            let p = SIMD3<Double>(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
            crossHit = (n, p)
        }
        capturing = target
        buffer.removeAll(keepingCapacity: true)
        framesLeft = totalFrames
        captureProgress = 0
        status = "Hold still — capturing \(target.title.lowercased())…"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func cancelCapture(_ message: String) {
        capturing = nil
        captureProgress = nil
        buffer = []
        status = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Unproject the central depth-map window to world points (high confidence only).
    private func extractPoints(frame: ARFrame, fraction: Double) {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let confMap = depthData.confidenceMap else { return }
        let depthMap = depthData.depthMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confMap, .readOnly)
        }
        guard let dBase = CVPixelBufferGetBaseAddress(depthMap),
              let cBase = CVPixelBufferGetBaseAddress(confMap) else { return }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let dStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let cStride = CVPixelBufferGetBytesPerRow(confMap)
        let dPtr = dBase.assumingMemoryBound(to: Float32.self)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)

        // Intrinsics are for the full-res image; scale to depth-map resolution.
        let K = frame.camera.intrinsics
        let res = frame.camera.imageResolution
        let fx = K[0][0] / (Float(res.width) / Float(w))
        let fy = K[1][1] / (Float(res.height) / Float(h))
        let cx = K[2][0] / (Float(res.width) / Float(w))
        let cy = K[2][1] / (Float(res.height) / Float(h))
        let camT = frame.camera.transform

        let ww = Int(Double(w) * fraction)
        let wh = Int(Double(h) * fraction)
        let x0 = (w - ww) / 2
        let y0 = (h - wh) / 2
        for v in stride(from: y0, to: y0 + wh, by: 2) {
            for u in stride(from: x0, to: x0 + ww, by: 2) {
                guard cPtr[v * cStride + u] >= ARConfidenceLevel.high.rawValue else { continue }
                let d = dPtr[v * dStride + u]
                guard d.isFinite, d > 0.12, d < 4.0 else { continue }
                let xc = (Float(u) + 0.5 - cx) * d / fx
                let yc = (Float(v) + 0.5 - cy) * d / fy
                let world = camT * SIMD4<Float>(xc, -yc, -d, 1)
                buffer.append(SIMD3(world.x, world.y, world.z))
            }
        }
    }

    private func finishCapture(_ label: SurfaceLabel, camera: ARCamera) {
        capturing = nil
        captureProgress = nil
        let pts = buffer
        buffer = []
        let cam = camera.transform.columns.3
        let viewPoint = SIMD3<Double>(Double(cam.x), Double(cam.y), Double(cam.z))
        let minPts = label.windowFraction > 0.15 ? 3000 : 400
        guard pts.count >= minPts, let fit = fitPlane(points: pts, viewPoint: viewPoint) else {
            cancelCapture("Not enough clean depth data — move closer and retry")
            return
        }

        var warning: String?
        if fit.sigma > 0.008 {
            warning = "Surface uneven (σ \(String(format: "%.0f", fit.sigma * 1000)) mm) — try a barer patch"
        }
        if fit.inlierFraction < 0.6 {
            warning = "Window looks cluttered (\(Int(fit.inlierFraction * 100))% flat) — try a barer patch"
        }
        let verticalness = abs(fit.normal.y)
        if label.expectsVertical, verticalness > 0.35 {
            warning = "That doesn't look vertical — recapture \(label.title.lowercased())?"
        } else if !label.expectsVertical, verticalness < 0.85 {
            warning = "That doesn't look horizontal — recapture \(label.title.lowercased())?"
        }

        surfaces[label] = CapturedSurface(label: label, fit: fit,
                                          crossNormal: crossHit?.normal, crossPoint: crossHit?.point,
                                          warning: warning)
        UINotificationFeedbackGenerator().notificationOccurred(warning == nil ? .success : .warning)
        status = warning ?? "\(label.title) ✓  σ \(String(format: "%.1f", fit.sigma * 1000)) mm · \(fit.count) pts"
        recompute()
        rebuildOverlay()
        if warning == nil, let next = captureOrder.first(where: { surfaces[$0] == nil }) {
            target = next
        }
    }

    // MARK: Measurements

    private func recompute() {
        var out: [Measurement] = []
        for def in measurementDefs {
            guard let a = surfaces[def.a], let b = surfaces[def.b] else { continue }
            let gap = planeGap(a.fit, b.fit)
            let d = gap.meters * calibration
            // World-scale error dominates: ~0.4% raw ARKit, ~0.15% after user calibration.
            let rel = abs(calibration - 1) > 1e-4 ? 0.0015 : 0.004
            let pm = max((gap.standardError * gap.standardError + rel * d * rel * d).squareRoot(), 0.0254 / 32)
            var cross: Double?
            if let na = a.crossNormal, let pa = a.crossPoint, let nb = b.crossNormal, let pb = b.crossPoint {
                let d1 = abs(simd_dot(pa - pb, nb))
                let d2 = abs(simd_dot(pb - pa, na))
                cross = (d1 + d2) / 2 * calibration - d
            }
            out.append(Measurement(name: def.name, meters: d, plusMinus: pm,
                                   angleDegrees: gap.angleDegrees, crossCheckDelta: cross))
        }
        measurements = out
    }

    func calibrate(_ measurement: Measurement, trueMeters: Double) {
        guard measurement.meters > 0.01, trueMeters > 0.01 else { return }
        calibration *= trueMeters / measurement.meters
        UserDefaults.standard.set(calibration, forKey: "calibrationScale")
        recompute()
        rebuildOverlay()
    }

    func resetCalibration() {
        calibration = 1
        UserDefaults.standard.removeObject(forKey: "calibrationScale")
        recompute()
        rebuildOverlay()
    }

    func removeSurface(_ label: SurfaceLabel) {
        surfaces[label] = nil
        target = label
        recompute()
        rebuildOverlay()
    }

    func reset() {
        capturing = nil
        captureProgress = nil
        buffer = []
        surfaces.removeAll()
        measurements = []
        target = captureOrder[0]
        arView?.scene.anchors.removeAll()
        status = "Cleared — starting over"
    }

    // MARK: Torch (closets are dark; LiDAR is fine but tracking needs light)

    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    // MARK: AR overlay

    private func f3(_ v: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
    }

    private func rotation(from: SIMD3<Float>, to: SIMD3<Float>) -> simd_quatf {
        if simd_dot(from, to) < -0.999 {
            return simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))
        }
        return simd_quatf(from: from, to: to)
    }

    private func rebuildOverlay() {
        guard let arView else { return }
        arView.scene.anchors.removeAll()
        let root = AnchorEntity(world: SIMD3<Float>(0, 0, 0))
        arView.scene.addAnchor(root)
        for s in surfaces.values { root.addChild(discEntity(for: s)) }
        if let shell = shellEntity(cutaway: false) { root.addChild(shell) }
    }

    private func discEntity(for s: CapturedSurface) -> Entity {
        let mesh = MeshResource.generatePlane(width: 0.12, depth: 0.12, cornerRadius: 0.06)
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: s.label.uiColor)])
        let n = f3(s.fit.normal)
        entity.position = f3(s.fit.centroid) + n * 0.004
        entity.orientation = rotation(from: SIMD3<Float>(0, 1, 0), to: n)
        return entity
    }

    // MARK: Clean shell (shared by the AR overlay and the 3D viewer)

    private enum ShellFace: String, CaseIterable {
        case backWall, sideWall, ceiling, floor, soffit

        var base: UIColor {
            switch self {
            case .backWall: UIColor(red: 0.89, green: 0.87, blue: 0.84, alpha: 1)
            case .sideWall: UIColor(red: 0.94, green: 0.92, blue: 0.89, alpha: 1)
            case .ceiling: UIColor(red: 0.97, green: 0.96, blue: 0.95, alpha: 1)
            case .floor: UIColor(red: 0.72, green: 0.56, blue: 0.40, alpha: 1)
            case .soffit: UIColor(red: 0.87, green: 0.85, blue: 0.82, alpha: 1)
            }
        }
    }

    private static var materialCache: [ShellFace: UnlitMaterial] = [:]

    /// Unlit (so it reads the same in a dark closet) with a procedurally drawn
    /// texture: wood planks on the floor, edge-darkening "ambient occlusion"
    /// vignette on everything. All patterns are flip-symmetric so UV
    /// orientation can never put a feature on the wrong edge.
    private static func shellMaterial(_ face: ShellFace) -> UnlitMaterial {
        if let cached = materialCache[face] { return cached }
        var material = UnlitMaterial(color: face.base)
        let image = faceImage(face)
        if let cg = image.cgImage,
           let tex = try? TextureResource(image: cg, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(tex))
        }
        materialCache[face] = material
        return material
    }

    private static func faceImage(_ face: ShellFace) -> UIImage {
        let side: CGFloat = 512
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            face.base.setFill()
            c.fill(CGRect(origin: .zero, size: size))

            if face == .floor {
                let planks = 7
                let ph = side / CGFloat(planks)
                for i in 0..<planks {
                    let rect = CGRect(x: 0, y: CGFloat(i) * ph, width: side, height: ph)
                    shade(face.base, by: 1 + CGFloat((i * 37 % 9) - 4) / 90).setFill()
                    c.fill(rect)
                    UIColor.black.withAlphaComponent(0.25).setFill()
                    c.fill(CGRect(x: 0, y: rect.maxY - 1.5, width: side, height: 1.5))
                    UIColor.black.withAlphaComponent(0.06).setFill()
                    for j in 0..<3 { // faint grain streaks
                        let gy = rect.minY + ph * (CGFloat(j) + 0.5) / 3
                        c.fill(CGRect(x: CGFloat((i * 53 + j * 97) % 200), y: gy,
                                      width: side * 0.7, height: 0.8))
                    }
                }
            }

            // Fake AO: darken toward the plane borders.
            let space = CGColorSpaceCreateDeviceRGB()
            let edge = UIColor.black.withAlphaComponent(face == .floor ? 0.20 : 0.11).cgColor
            let clear = UIColor.black.withAlphaComponent(0).cgColor
            if let grad = CGGradient(colorsSpace: space, colors: [clear, edge] as CFArray, locations: [0, 1]) {
                let center = CGPoint(x: side / 2, y: side / 2)
                c.drawRadialGradient(grad, startCenter: center, startRadius: side * 0.38,
                                     endCenter: center, endRadius: side * 0.78,
                                     options: .drawsAfterEndLocation)
            }
        }
    }

    private static func shade(_ color: UIColor, by f: CGFloat) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: min(r * f, 1), green: min(g * f, 1), blue: min(b * f, 1), alpha: a)
    }

    /// Quad with UVs, wound so the front face points inward. `doubleSided` for
    /// the AR overlay (always visible); single-sided in the viewer gives the
    /// dollhouse cutaway — walls facing away from the camera disappear.
    private func quadEntity(_ p: [SIMD3<Float>], material: UnlitMaterial,
                            inward: SIMD3<Float>, doubleSided: Bool) -> Entity {
        var md = MeshDescriptor(name: "quad")
        md.positions = MeshBuffer(p)
        md.textureCoordinates = MeshBuffer([SIMD2<Float>(0, 0), SIMD2<Float>(1, 0),
                                            SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)])
        let faceNormal = simd_cross(p[1] - p[0], p[2] - p[0])
        var idx: [UInt32] = simd_dot(faceNormal, inward) > 0 ? [0, 1, 2, 0, 2, 3] : [2, 1, 0, 3, 2, 0]
        if doubleSided { idx += idx.reversed() }
        md.primitives = .triangles(idx)
        guard let mesh = try? MeshResource.generate(from: [md]) else { return Entity() }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    /// The clean empty-closet shell at the fitted planes. In AR it is drawn
    /// over the camera feed with no occlusion, so the real contents vanish.
    func shellEntity(cutaway: Bool) -> Entity? {
        guard let l = surfaces[.leftWall]?.fit, let r = surfaces[.rightWall]?.fit,
              let b = surfaces[.backWall]?.fit, let f = surfaces[.frontWall]?.fit,
              let fl = surfaces[.floor]?.fit, let c = surfaces[.ceiling]?.fit else { return nil }
        func corner(_ a: PlaneFit, _ b: PlaneFit, _ c: PlaneFit) -> SIMD3<Float>? {
            planeIntersection(a, b, c).map(f3)
        }
        guard
            let lbf = corner(l, b, fl), let rbf = corner(r, b, fl),
            let lbc = corner(l, b, c), let rbc = corner(r, b, c),
            let lff = corner(l, f, fl), let rff = corner(r, f, fl),
            let lfc = corner(l, f, c), let rfc = corner(r, f, c)
        else { return nil }

        let root = Entity()
        func add(_ pts: [SIMD3<Float>], _ face: ShellFace, _ inward: SIMD3<Float>) {
            root.addChild(quadEntity(pts, material: Self.shellMaterial(face),
                                     inward: inward, doubleSided: !cutaway))
        }
        // Corner order: bottom edge first so UV v runs floor → ceiling.
        add([lbf, rbf, rbc, lbc], .backWall, f3(b.normal))
        add([lbf, lff, lfc, lbc], .sideWall, f3(l.normal))
        add([rbf, rff, rfc, rbc], .sideWall, f3(r.normal))
        add([lbf, rbf, rff, lff], .floor, f3(fl.normal))
        add([lbc, rbc, rfc, lfc], .ceiling, f3(c.normal))

        // Soffit block: between its face and the front wall, underside up to ceiling.
        if let sb = surfaces[.soffitBottom]?.fit, let sf = surfaces[.soffitFace]?.fit,
           let a1 = corner(l, sf, sb), let a2 = corner(r, sf, sb),
           let a3 = corner(r, f, sb), let a4 = corner(l, f, sb),
           let a5 = corner(l, sf, c), let a6 = corner(r, sf, c) {
            add([a1, a2, a3, a4], .soffit, f3(sb.normal))
            add([a1, a2, a6, a5], .soffit, f3(sf.normal))
        }

        addDimensionText(at: (lbf + rbf + rbc + lbc) / 4, normal: f3(b.normal), to: root)
        return root
    }

    /// Shell prepared for the non-AR orbit viewer: centered on the origin,
    /// opening rotated toward the default camera, scaled to ~1 m.
    func viewerEntity() -> Entity? {
        guard let shell = shellEntity(cutaway: true),
              let back = surfaces[.backWall]?.fit else { return nil }
        let bounds = shell.visualBounds(relativeTo: nil)
        shell.position -= bounds.center
        let outer = Entity()
        outer.addChild(shell)
        let n = f3(back.normal) // inward = toward the opening
        outer.orientation = simd_quatf(angle: atan2(n.x, n.z), axis: SIMD3<Float>(0, 1, 0))
        let maxExtent = max(bounds.extents.x, max(bounds.extents.y, bounds.extents.z))
        if maxExtent > 0 { outer.scale = SIMD3<Float>(repeating: 1.1 / maxExtent) }
        return outer
    }

    private func addDimensionText(at center: SIMD3<Float>, normal: SIMD3<Float>, to root: Entity) {
        let up0 = SIMD3<Float>(0, 1, 0)
        let fwd = simd_normalize(normal)
        guard abs(simd_dot(fwd, up0)) < 0.9 else { return }
        let right = simd_normalize(simd_cross(up0, fwd))
        let up = simd_cross(fwd, right)
        let rot = simd_quatf(simd_float3x3(columns: (right, up, fwd)))

        let wanted = [("Width", "W"), ("Depth", "D"), ("Height", "H")]
        let lines: [String] = wanted.compactMap { name, letter in
            measurements.first { $0.name == name }.map { "\(letter)  \(inchString($0.meters))" }
        }
        for (i, line) in lines.enumerated() {
            let mesh = MeshResource.generateText(line, extrusionDepth: 0.002,
                                                 font: .systemFont(ofSize: 0.055, weight: .semibold),
                                                 containerFrame: .zero, alignment: .center,
                                                 lineBreakMode: .byWordWrapping)
            let model = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(white: 0.25, alpha: 1))])
            let bounds = mesh.bounds
            model.position = SIMD3<Float>(-bounds.center.x, -bounds.center.y, 0)
            let holder = Entity()
            holder.addChild(model)
            holder.position = center + fwd * 0.02 + up * (0.10 - Float(i) * 0.09)
            holder.orientation = rot
            root.addChild(holder)
        }
    }
}

extension SurfaceLabel {
    var uiColor: UIColor {
        switch self {
        case .leftWall: .systemBlue
        case .rightWall: .systemTeal
        case .backWall: .systemIndigo
        case .frontWall: .systemPurple
        case .floor: .systemBrown
        case .ceiling: .systemGray
        case .soffitBottom: .systemOrange
        case .soffitFace: .systemYellow
        case .doorLeftJamb: .systemGreen
        case .doorRightJamb: .systemMint
        case .doorHead: .systemCyan
        }
    }

    var color: Color { Color(uiColor: uiColor) }
}
