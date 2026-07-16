//
//  ScanView.swift
//  ClosetScanner
//
//  AR camera + HUD: reticle, guided surface chips, capture button, live
//  measurements, and the 3D viewer sheet.
//

import SwiftUI
import RealityKit
import ARKit

struct ScanView: View {
    @StateObject private var controller: CaptureController
    private let onExit: () -> Void

    @State private var showResetConfirm = false
    @State private var showExitConfirm = false
    @State private var showViewer = false
    @State private var calibrateTarget: Measurement?
    @State private var calibrateText = ""

    init(hasSoffit: Bool, onExit: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: CaptureController(hasSoffit: hasSoffit))
        self.onExit = onExit
    }

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller)
                .ignoresSafeArea()

            scrims
            reticle.offset(y: -40)

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controller.stop()
        }
        .sheet(isPresented: $showViewer) { ShellViewer(controller: controller) }
        .confirmationDialog("Clear all captured surfaces?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Clear scan", role: .destructive) { controller.reset() }
        }
        .confirmationDialog("Leave the scan? Captures will be lost.", isPresented: $showExitConfirm, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { onExit() }
        }
        .alert("Calibrate scale", isPresented: calibrateAlertBinding, presenting: calibrateTarget) { m in
            TextField("True \(m.name.lowercased()) in inches, e.g. 27 3/16", text: $calibrateText)
                .keyboardType(.numbersAndPunctuation)
            Button("Apply") {
                if let meters = parseInches(calibrateText) {
                    controller.calibrate(m, trueMeters: meters)
                }
                calibrateText = ""
            }
            Button("Cancel", role: .cancel) { calibrateText = "" }
        } message: { m in
            Text("App measured \(inchString(m.meters)). Enter the tape-measured value to set a scale correction for all measurements.")
        }
    }

    private var calibrateAlertBinding: Binding<Bool> {
        Binding(get: { calibrateTarget != nil }, set: { if !$0 { calibrateTarget = nil } })
    }

    // MARK: Scrims (readability over the camera feed)

    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 330)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: Top

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            hudButton("xmark") {
                if controller.surfaces.isEmpty { onExit() } else { showExitConfirm = true }
            }
            statusCapsule
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                hudButton(controller.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                          tint: controller.torchOn ? .yellow : .white) {
                    controller.torchOn.toggle()
                }
                hudButton("trash") { showResetConfirm = true }
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var statusCapsule: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(CaptureController.lidarAvailable ? controller.status : "This device has no LiDAR — scanning unavailable")
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(controller.stepText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if controller.calibration != 1 {
                    Text(String(format: "cal ×%.4f", controller.calibration))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .contextMenu {
                            Button("Reset calibration", role: .destructive) { controller.resetCalibration() }
                        }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func hudButton(_ systemName: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: Reticle

    private var reticle: some View {
        let side = 90 + CGFloat(controller.target.windowFraction) * 320
        return ZStack {
            ReticleShape()
                .stroke(controller.target.color,
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.4), radius: 2)
            Circle()
                .fill(controller.target.color)
                .frame(width: 5, height: 5)
        }
        .frame(width: side, height: side)
        .opacity(controller.captureProgress == nil ? 0.95 : 0.45)
        .animation(.easeInOut(duration: 0.25), value: controller.target)
        .allowsHitTesting(false)
    }

    // MARK: Bottom

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            if !controller.measurements.isEmpty { measurementCard }
            chipRow
            captureButton
        }
        .padding(.bottom, 12)
    }

    private var chipRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(controller.captureOrder) { label in
                        chip(label).id(label)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: controller.target) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }

    private func chip(_ label: SurfaceLabel) -> some View {
        let captured = controller.surfaces[label] != nil
        let isTarget = controller.target == label
        return Button {
            controller.target = label
        } label: {
            HStack(spacing: 5) {
                if captured {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(isTarget ? .white : .green)
                } else {
                    Circle().fill(label.color).frame(width: 8, height: 8)
                }
                Text(label.short).font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isTarget ? AnyShapeStyle(label.color.opacity(0.92)) : AnyShapeStyle(.ultraThinMaterial),
                        in: Capsule())
        }
        .contextMenu {
            if captured {
                Button("Recapture") { controller.target = label }
                Button("Remove", role: .destructive) { controller.removeSurface(label) }
            }
        }
        .foregroundStyle(.white)
    }

    private var captureButton: some View {
        VStack(spacing: 6) {
            Button(action: controller.beginCapture) {
                ZStack {
                    Circle()
                        .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                        .frame(width: 78, height: 78)
                    Circle()
                        .fill(controller.trackingNormal ? Color.white : Color.gray.opacity(0.5))
                        .frame(width: 64, height: 64)
                    if let p = controller.captureProgress {
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(controller.target.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 78, height: 78)
                    }
                    Image(systemName: "viewfinder")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.black.opacity(controller.trackingNormal ? 0.8 : 0.3))
                }
            }
            .disabled(!controller.trackingNormal || controller.captureProgress != nil)
            Text(controller.target.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.5), radius: 2)
        }
    }

    private var measurementCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("MEASUREMENTS")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if controller.shellVisible {
                    Button {
                        showViewer = true
                    } label: {
                        Label("3D view", systemImage: "cube.transparent")
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            ForEach(controller.measurements) { m in
                Button { calibrateTarget = m } label: { measurementRow(m) }
                    .buttonStyle(.plain)
                if m.id != controller.measurements.last?.id {
                    Divider().padding(.leading, 14)
                }
            }
        }
        .padding(.bottom, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }

    private func measurementRow(_ m: Measurement) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.subheadline.weight(.medium))
                if m.angleDegrees > 1.5 {
                    Text(String(format: "∠ %.1f° out of parallel", m.angleDegrees))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(inchString(m.meters))  ± \(sixteenthsString(pmSixteenths(m)))″")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                HStack(spacing: 6) {
                    Text(cmString(m.meters)).font(.caption2).foregroundStyle(.secondary)
                    if let delta = m.crossCheckDelta {
                        crossBadge(delta)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func pmSixteenths(_ m: Measurement) -> Int {
        max(Int((m.plusMinus / 0.0254 * 16).rounded(.up)), 1)
    }

    private func crossBadge(_ delta: Double) -> some View {
        let agrees = abs(delta) <= 0.0254 / 8
        return HStack(spacing: 2) {
            Image(systemName: agrees ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            Text("ARKit Δ \(inchString(abs(delta)))")
        }
        .font(.caption2)
        .foregroundStyle(agrees ? .green : .orange)
    }
}

// MARK: - Corner-bracket reticle

private struct ReticleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let l = min(rect.width, rect.height) * 0.22
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        // top-left
        p.move(to: CGPoint(x: x0, y: y0 + l)); p.addLine(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x0 + l, y: y0))
        // top-right
        p.move(to: CGPoint(x: x1 - l, y: y0)); p.addLine(to: CGPoint(x: x1, y: y0)); p.addLine(to: CGPoint(x: x1, y: y0 + l))
        // bottom-right
        p.move(to: CGPoint(x: x1, y: y1 - l)); p.addLine(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x1 - l, y: y1))
        // bottom-left
        p.move(to: CGPoint(x: x0 + l, y: y1)); p.addLine(to: CGPoint(x: x0, y: y1)); p.addLine(to: CGPoint(x: x0, y: y1 - l))
        return p
    }
}

// MARK: - 3D orbit viewer

struct ShellViewer: View {
    @ObservedObject var controller: CaptureController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RealityView { content in
                    content.camera = .virtual
                    if let entity = controller.viewerEntity() {
                        content.add(entity)
                    }
                }
                .realityViewCameraControls(.orbit)
                summary
            }
            .background(
                LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)],
                               startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            )
            .navigationTitle("Empty Closet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var summary: some View {
        VStack(spacing: 6) {
            if let line = mainLine {
                Text(line)
                    .font(.headline.monospacedDigit())
            }
            ForEach(extraMeasurements) { m in
                Text("\(m.name): \(inchString(m.meters))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Drag to orbit · pinch to zoom")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private var mainLine: String? {
        func value(_ name: String) -> String? {
            controller.measurements.first { $0.name == name }.map { inchString($0.meters) }
        }
        guard let w = value("Width"), let d = value("Depth"), let h = value("Height") else { return nil }
        return "\(w) W × \(d) D × \(h) H"
    }

    private var extraMeasurements: [Measurement] {
        controller.measurements.filter { !["Width", "Depth", "Height"].contains($0.name) }
    }
}

// MARK: - ARView bridge

private struct ARViewContainer: UIViewRepresentable {
    let controller: CaptureController

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)
        controller.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
