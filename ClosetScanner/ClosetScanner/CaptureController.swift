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

    @Published var target: SurfaceLabel = .leftWall
    @Published private(set) var surfaces: [SurfaceLabel: CapturedSurface] = [:]
    @Published private(set) var measurements: [Measurement] = []
    @Published private(set) var captureProgress: Double?
    @Published private(set) var status = "Starting camera…"
    @Published private(set) var trackingNormal = false
    @Published var torchOn = false { didSet { setTorch(torchOn) } }
    @Published private(set) var calibration = UserDefaults.standard.object(forKey: "calibrationScale") as? Double ?? 1.0

    var shellVisible: Bool { SurfaceLabel.coreOrder.allSatisfy { surfaces[$0] != nil } }

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
        if shellVisible, surfaces.count == SurfaceLabel.coreOrder.count {
            return "Closet captured — optional: soffit and door surfaces"
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
        if warning == nil, let next = SurfaceLabel.coreOrder.first(where: { surfaces[$0] == nil }) {
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
        target = .leftWall
        arView?.scene.anchors.removeAll()
        status = "Cleared — aim at the left wall"
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
        if shellVisible { addShell(to: root) }
    }

    private func discEntity(for s: CapturedSurface) -> Entity {
        let mesh = MeshResource.generatePlane(width: 0.13, depth: 0.13, cornerRadius: 0.065)
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: s.label.uiColor)])
        let n = f3(s.fit.normal)
        entity.position = f3(s.fit.centroid) + n * 0.004
        entity.orientation = rotation(from: SIMD3<Float>(0, 1, 0), to: n)
        return entity
    }

    /// Double-sided flat-colored quad — winding-proof, lighting-proof (dark closets).
    private func quadEntity(_ p: [SIMD3<Float>], _ color: UIColor) -> Entity {
        var md = MeshDescriptor(name: "quad")
        md.positions = MeshBuffer(p)
        md.primitives = .triangles([0, 1, 2, 0, 2, 3, 2, 1, 0, 3, 2, 0])
        guard let mesh = try? MeshResource.generate(from: [md]) else { return Entity() }
        return ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
    }

    /// The clean empty-closet shell: opaque quads at the fitted planes. Drawn
    /// over the camera feed with no occlusion, so real contents vanish.
    private func addShell(to root: Entity) {
        guard let l = surfaces[.leftWall]?.fit, let r = surfaces[.rightWall]?.fit,
              let b = surfaces[.backWall]?.fit, let f = surfaces[.frontWall]?.fit,
              let fl = surfaces[.floor]?.fit, let c = surfaces[.ceiling]?.fit else { return }
        func corner(_ a: PlaneFit, _ b: PlaneFit, _ c: PlaneFit) -> SIMD3<Float>? {
            planeIntersection(a, b, c).map(f3)
        }
        guard
            let lbf = corner(l, b, fl), let rbf = corner(r, b, fl),
            let lbc = corner(l, b, c), let rbc = corner(r, b, c),
            let lff = corner(l, f, fl), let rff = corner(r, f, fl),
            let lfc = corner(l, f, c), let rfc = corner(r, f, c)
        else { return }

        root.addChild(quadEntity([lbf, rbf, rbc, lbc], UIColor(red: 0.89, green: 0.87, blue: 0.83, alpha: 1))) // back
        root.addChild(quadEntity([lbf, lbc, lfc, lff], UIColor(red: 0.94, green: 0.92, blue: 0.89, alpha: 1))) // left
        root.addChild(quadEntity([rbf, rbc, rfc, rff], UIColor(red: 0.92, green: 0.90, blue: 0.86, alpha: 1))) // right
        root.addChild(quadEntity([lbf, rbf, rff, lff], UIColor(red: 0.76, green: 0.62, blue: 0.45, alpha: 1))) // floor
        root.addChild(quadEntity([lbc, rbc, rfc, lfc], UIColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1))) // ceiling

        // Soffit block: between its face and the front wall, underside up to ceiling.
        if let sb = surfaces[.soffitBottom]?.fit, let sf = surfaces[.soffitFace]?.fit,
           let a1 = corner(l, sf, sb), let a2 = corner(r, sf, sb),
           let a3 = corner(r, f, sb), let a4 = corner(l, f, sb),
           let a5 = corner(l, sf, c), let a6 = corner(r, sf, c) {
            root.addChild(quadEntity([a1, a2, a3, a4], UIColor(red: 0.87, green: 0.85, blue: 0.81, alpha: 1))) // underside
            root.addChild(quadEntity([a1, a2, a6, a5], UIColor(red: 0.84, green: 0.82, blue: 0.78, alpha: 1))) // face
        }

        addDimensionText(at: (lbf + rbf + rbc + lbc) / 4, normal: f3(b.normal), to: root)
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
