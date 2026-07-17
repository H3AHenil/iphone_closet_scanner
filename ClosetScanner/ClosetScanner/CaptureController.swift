//
//  CaptureController.swift
//  ClosetScanner
//
//  Owns the ARSession. Capture = accumulate high-confidence LiDAR depth pixels
//  from a reticle window over ~40 frames, unproject to world space, and fit a
//  robust plane. Dimensions are plane-to-plane gaps, so boxes/cabinets hiding
//  the corners never matter. The final above-door capture (from inside)
//  locates the door head line by crossing through-the-opening rays with the
//  captured front-wall plane (see finishHeadCapture). Once everything is
//  captured we render an opaque clean shell at the fitted planes — the closet
//  looks empty on screen.
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

    /// The shell (AR overlay and 3D view) only appears once the guided flow is
    /// complete — an opaque render mid-flow would cover the surfaces still to
    /// be captured.
    var shellVisible: Bool { allCaptured && surfaces[.frontWall] != nil }
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
    /// Per-point camera position, collected only for the above-door edge
    /// capture (rays through the opening need their origin).
    private var originBuffer: [SIMD3<Float>] = []
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
        originBuffer.removeAll()
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
        extractPoints(frame: frame, fraction: label.windowFraction, collectOrigins: label == .doorHead)
        framesLeft -= 1
        captureProgress = 1 - Double(framesLeft) / Double(totalFrames)
        if framesLeft <= 0 { finishCapture(label, camera: frame.camera) }
    }

    private func idleStatus() -> String {
        if allCaptured {
            return "All surfaces captured — open the 3D view"
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
        originBuffer.removeAll(keepingCapacity: true)
        framesLeft = totalFrames
        captureProgress = 0
        status = "Hold still — capturing \(target.title.lowercased())…"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func cancelCapture(_ message: String) {
        capturing = nil
        captureProgress = nil
        buffer = []
        originBuffer = []
        status = message
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Unproject the central depth-map window to world points (high confidence only).
    private func extractPoints(frame: ARFrame, fraction: Double, collectOrigins: Bool) {
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
        let origin = SIMD3<Float>(camT.columns.3.x, camT.columns.3.y, camT.columns.3.z)

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
                if collectOrigins { originBuffer.append(origin) }
            }
        }
    }

    private func finishCapture(_ label: SurfaceLabel, camera: ARCamera) {
        if label == .doorHead {
            finishHeadCapture()
            return
        }
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
        // A jamb reveal is perpendicular to the front/back walls. Near-parallel
        // means the wall face got scanned instead — and parallel planes would
        // send the door-corner intersections to infinity in the render.
        if label == .doorLeftJamb || label == .doorRightJamb,
           let back = surfaces[.backWall]?.fit,
           abs(simd_dot(fit.normal, back.normal)) > 0.7 {
            warning = "That looks like the wall face, not the inner reveal — recapture \(label.title.lowercased())?"
        }
        // The front wall must be parallel to the back wall (depth is the gap
        // between them). A skewed fit means the window caught the wrong surface.
        if label == .frontWall,
           let back = surfaces[.backWall]?.fit,
           abs(simd_dot(fit.normal, back.normal)) < 0.8 {
            warning = "That doesn't look parallel to the back wall — recapture front wall?"
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

    /// The above-door capture, done from INSIDE the closet, locates the door
    /// head line. The window straddles the top edge of the opening: rays that
    /// land ≥15 cm behind the already-captured front-wall plane went out
    /// through the opening, and where they cross that plane fills the opening
    /// up to a sharp cutoff at the head. Points on the wall or soffit above
    /// the edge simply produce no crossings — so this works the same whether
    /// the strip above the door is front wall or soffit.
    private func finishHeadCapture() {
        capturing = nil
        captureProgress = nil
        let pts = buffer, origins = originBuffer
        buffer = []
        originBuffer = []
        guard let front = surfaces[.frontWall]?.fit,
              let jl = surfaces[.doorLeftJamb]?.fit, let jr = surfaces[.doorRightJamb]?.fit else {
            cancelCapture("Capture the front wall and both jambs before the top of the opening")
            return
        }
        guard pts.count >= 1500, pts.count == origins.count else {
            cancelCapture("Not enough clean depth data — back up a little inside the closet and retry")
            return
        }
        // Only rays that crossed the front-wall plane INSIDE the opening count —
        // between the jamb reveals and below the ceiling. Rays slipping past
        // the wall's outer edges would otherwise fake crossings above the head.
        let ceiling = surfaces[.ceiling]?.fit
        func insideOpening(_ x: SIMD3<Double>) -> Bool {
            simd_dot(x - jl.centroid, jl.normal) > 0.02
                && simd_dot(x - jr.centroid, jr.normal) > 0.02
                && (ceiling.map { simd_dot(x - $0.centroid, $0.normal) > 0.02 } ?? true)
        }
        var crossings: [SIMD3<Double>] = []
        for (p, o) in zip(pts, origins) {
            let pd = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z))
            guard simd_dot(pd - front.centroid, front.normal) < -0.15 else { continue }
            let od = SIMD3<Double>(Double(o.x), Double(o.y), Double(o.z))
            if let x = rayPlaneCrossing(origin: od, through: pd, planeNormal: front.normal, planePoint: front.centroid),
               insideOpening(x) {
                crossings.append(x)
            }
        }
        guard let head = headLineFit(crossings: crossings) else {
            cancelCapture("Couldn't see through the opening — frame the top edge, half wall / half opening")
            return
        }
        surfaces[.doorHead] = CapturedSurface(label: .doorHead, fit: head,
                                              crossNormal: nil, crossPoint: nil, warning: nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        status = "Above door ✓  head line from \(head.count) edge points"
        recompute()
        rebuildOverlay()
        if let next = captureOrder.first(where: { surfaces[$0] == nil }) { target = next }
    }

    // MARK: Measurements

    private func recompute() {
        var out: [Measurement] = []
        for def in measurementDefs {
            guard let a = surfaces[def.a], let b = surfaces[def.b] else { continue }
            let gap = planeGap(a.fit, b.fit)
            let d = gap.meters
            // World-scale error dominates: ~0.4% of the span for raw ARKit.
            let rel = 0.004
            // The head line is edge-derived and carries ~4 mm of localization error.
            let edge = [def.a, def.b].contains(.doorHead) ? 0.004 : 0
            let pm = max((gap.standardError * gap.standardError + rel * d * rel * d + edge * edge).squareRoot(), 0.0254 / 32)
            var cross: Double?
            if let na = a.crossNormal, let pa = a.crossPoint, let nb = b.crossNormal, let pb = b.crossPoint {
                let d1 = abs(simd_dot(pa - pb, nb))
                let d2 = abs(simd_dot(pb - pa, na))
                cross = (d1 + d2) / 2 - d
            }
            out.append(Measurement(name: def.name, meters: d, plusMinus: pm,
                                   angleDegrees: gap.angleDegrees, crossCheckDelta: cross))
        }
        measurements = out
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
        originBuffer = []
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
        if shellVisible, let shell = shellEntity(style: .ar) { root.addChild(shell) }
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

    /// Double-sided quad with UVs (bottom edge first so UV v runs floor → ceiling).
    private func quadEntity(_ p: [SIMD3<Float>], material: UnlitMaterial) -> Entity {
        var md = MeshDescriptor(name: "quad")
        md.positions = MeshBuffer(p)
        md.textureCoordinates = MeshBuffer([SIMD2<Float>(0, 0), SIMD2<Float>(1, 0),
                                            SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)])
        md.primitives = .triangles([0, 1, 2, 0, 2, 3, 2, 1, 0, 3, 2, 0])
        guard let mesh = try? MeshResource.generate(from: [md]) else { return Entity() }
        return ModelEntity(mesh: mesh, materials: [material])
    }

    enum ShellStyle {
        /// Opaque textured shell drawn over the camera feed (hides the real contents).
        case ar
        /// Semi-transparent glass box with edge lines and dimension labels.
        case viewer
    }

    /// Translucent tints for the viewer's glass-box look.
    private static func glassMaterial(_ face: ShellFace) -> UnlitMaterial {
        let opacity: Float = switch face {
        case .floor: 0.92
        case .backWall: 0.24
        case .sideWall: 0.16
        case .ceiling: 0.10
        case .soffit: 0.22
        }
        var m = UnlitMaterial(color: face == .floor ? face.base : UIColor(white: 0.85, alpha: 1))
        m.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return m
    }

    private func faceMaterial(_ face: ShellFace, _ style: ShellStyle) -> UnlitMaterial {
        style == .ar ? Self.shellMaterial(face) : Self.glassMaterial(face)
    }

    /// The clean empty-closet shell at the fitted planes, including the front
    /// wall with the door opening cut out (when the door was captured).
    func shellEntity(style: ShellStyle) -> Entity? {
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
        func add(_ pts: [SIMD3<Float>], _ face: ShellFace) {
            root.addChild(quadEntity(pts, material: faceMaterial(face, style)))
        }
        // Any legitimate feature corner lies within the closet box; reject
        // intersections that shot toward infinity from a bad capture.
        let boxCenter = (lbf + rfc) / 2
        let boxReach = simd_length(rfc - lbf)
        func withinBox(_ pts: [SIMD3<Float>]) -> Bool {
            pts.allSatisfy { simd_length($0 - boxCenter) < boxReach }
        }
        add([lbf, rbf, rbc, lbc], .backWall)
        add([lbf, lff, lfc, lbc], .sideWall)
        add([rbf, rff, rfc, rbc], .sideWall)
        add([lbf, rbf, rff, lff], .floor)
        add([lbc, rbc, rfc, lfc], .ceiling)

        // Front wall as three panels around the door opening. Jambs that are
        // near-parallel to the front wall (wall face scanned by mistake) would
        // put the intersections near infinity — skip the opening instead.
        var doorCorners: [SIMD3<Float>]? // dlf, drf, drh, dlh
        if let jl = surfaces[.doorLeftJamb]?.fit, let jr = surfaces[.doorRightJamb]?.fit,
           let head = surfaces[.doorHead]?.fit,
           abs(simd_dot(jl.normal, f.normal)) < 0.7, abs(simd_dot(jr.normal, f.normal)) < 0.7,
           let dlf = corner(f, jl, fl), let drf = corner(f, jr, fl),
           let dlh = corner(f, jl, head), let drh = corner(f, jr, head),
           let dlc = corner(f, jl, c), let drc = corner(f, jr, c),
           dlh.y > dlf.y, dlh.y < dlc.y, drh.y > drf.y, drh.y < drc.y,
           withinBox([dlf, drf, dlh, drh, dlc, drc]) {
            add([lff, dlf, dlc, lfc], .sideWall)
            add([drf, rff, rfc, drc], .sideWall)
            add([dlh, drh, drc, dlc], .sideWall)
            doorCorners = [dlf, drf, drh, dlh]
        }

        // Soffit block: the underside runs only from the soffit face to the
        // front wall (the soffit depth), the face from its bottom edge up to
        // the ceiling. Bounds-checked so a bad capture (e.g. a near-horizontal
        // "face" fit) can never stretch the block toward infinity.
        if let sb = surfaces[.soffitBottom]?.fit, let sf = surfaces[.soffitFace]?.fit,
           let a1 = corner(l, sf, sb), let a2 = corner(r, sf, sb),
           let a3 = corner(r, f, sb), let a4 = corner(l, f, sb),
           let a5 = corner(l, sf, c), let a6 = corner(r, sf, c),
           withinBox([a1, a2, a3, a4, a5, a6]) {
            add([a1, a2, a3, a4], .soffit)
            add([a1, a2, a6, a5], .soffit)
        }

        switch style {
        case .ar:
            addDimensionText(at: (lbf + rbf + rbc + lbc) / 4, normal: f3(b.normal), to: root)
        case .viewer:
            let maxExtent = max(simd_length(rff - lff), simd_length(lfc - lff), simd_length(lbf - lff))
            let thickness = 0.0025 * maxExtent
            let boxEdges = [(lbf, rbf), (rbf, rff), (rff, lff), (lff, lbf),
                            (lbc, rbc), (rbc, rfc), (rfc, lfc), (lfc, lbc),
                            (lbf, lbc), (rbf, rbc), (lff, lfc), (rff, rfc)]
            for (a, b) in boxEdges { root.addChild(edgeEntity(a, b, thickness: thickness)) }
            if let dc = doorCorners {
                for i in 0..<4 { root.addChild(edgeEntity(dc[i], dc[(i + 1) % 4], thickness: thickness)) }
            }

            let up = simd_normalize(lfc - lff)
            let left = simd_normalize(lff - rff)
            let front = simd_normalize(lff - lbf)
            let off = 0.06 * maxExtent
            let size = 0.035 * maxExtent
            func measured(_ name: String) -> Double? {
                measurements.first { $0.name == name }?.meters
            }
            if let h = measured("Height") {
                root.addChild(viewerLabel("H  \(feetInchString(h))",
                                          at: (lff + lfc) / 2 + left * off + front * off * 0.3, size: size))
            }
            if let w = measured("Width") {
                root.addChild(viewerLabel("W  \(feetInchString(w))",
                                          at: (lff + rff) / 2 - up * off + front * off * 0.5, size: size))
            }
            if let d = measured("Depth") {
                root.addChild(viewerLabel(feetInchString(d),
                                          at: (rff + rbf) / 2 - left * off - up * off * 0.3, size: size))
            }
        }
        return root
    }

    /// Thin white line between two corners.
    private func edgeEntity(_ a: SIMD3<Float>, _ b: SIMD3<Float>, thickness: Float) -> Entity {
        let mesh = MeshResource.generateBox(size: SIMD3(simd_length(b - a), thickness, thickness))
        let e = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 1))])
        e.position = (a + b) / 2
        e.orientation = rotation(from: SIMD3<Float>(1, 0, 0), to: simd_normalize(b - a))
        return e
    }

    /// White billboarded dimension label.
    private func viewerLabel(_ text: String, at pos: SIMD3<Float>, size: Float) -> Entity {
        let mesh = MeshResource.generateText(text, extrusionDepth: size * 0.02,
                                             font: .systemFont(ofSize: CGFloat(size), weight: .medium),
                                             containerFrame: .zero, alignment: .center,
                                             lineBreakMode: .byWordWrapping)
        let model = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: .white)])
        let b = mesh.bounds
        model.position = SIMD3<Float>(-b.center.x, -b.center.y, 0)
        let holder = Entity()
        holder.addChild(model)
        holder.position = pos
        holder.components.set(BillboardComponent())
        return holder
    }

    /// Shell prepared for the non-AR orbit viewer: centered on the origin,
    /// opening rotated toward the default camera, scaled to ~1 m.
    func viewerEntity() -> Entity? {
        guard let shell = shellEntity(style: .viewer),
              let back = surfaces[.backWall]?.fit else { return nil }
        let bounds = shell.visualBounds(relativeTo: nil)
        shell.position -= bounds.center
        let outer = Entity()
        outer.addChild(shell)
        let n = f3(back.normal) // inward = toward the opening
        outer.orientation = simd_quatf(angle: atan2(n.x, n.z) + 0.35, axis: SIMD3<Float>(0, 1, 0))
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
