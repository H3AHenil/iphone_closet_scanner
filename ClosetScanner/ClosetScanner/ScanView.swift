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
            Text(controller.stepText)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
        // Forced capture order: the current step, the next uncaptured step
        // (so a capture warning never strands the flow), and recaptures.
        let isNext = label == controller.captureOrder.first { controller.surfaces[$0] == nil }
        return Button {
            controller.target = label
        } label: {
            chipLabel(label, captured: captured, isTarget: isTarget)
        }
        .disabled(!captured && !isTarget && !isNext)
        .opacity(captured || isTarget || isNext ? 1 : 0.45)
        .contextMenu {
            if captured {
                Button("Recapture") { controller.target = label }
                Button("Remove", role: .destructive) { controller.removeSurface(label) }
            }
        }
        .foregroundStyle(.white)
    }

    private func chipLabel(_ label: SurfaceLabel, captured: Bool, isTarget: Bool) -> some View {
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
                measurementRow(m)
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
        VStack(spacing: 0) {
            RealityView { content in
                content.camera = .virtual
                if let entity = controller.viewerEntity() {
                    content.add(entity)
                }
            }
            .realityViewCameraControls(.orbit)
            panel
        }
        .background(Color(white: 0.07).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func measurement(_ name: String) -> Measurement? {
        controller.measurements.first { $0.name == name }
    }

    private var extraMeasurements: [Measurement] {
        controller.measurements.filter { !["Width", "Depth", "Height"].contains($0.name) }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color(white: 0.35))
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 6)

            ForEach(["Width", "Depth", "Height"], id: \.self) { name in
                if let m = measurement(name) { mainRow(m) }
            }
            ForEach(extraMeasurements) { m in smallRow(m) }

            Button {
                dismiss()
            } label: {
                Text("Rescan")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(.blue, in: Capsule())
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 26)
        }
        .background(Color(white: 0.14), in: UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32))
        .padding(.horizontal, 6)
    }

    private func mainRow(_ m: Measurement) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(m.name)
                .font(.title3)
                .foregroundStyle(Color(white: 0.62))
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(feetInchString(m.meters))
                    .font(.title.weight(.bold))
                Text("\(String(format: "%.2f", m.meters / 0.0254)) in · \(cmString(m.meters))")
                    .font(.subheadline)
                    .foregroundStyle(Color(white: 0.55))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
    }

    private func smallRow(_ m: Measurement) -> some View {
        HStack {
            Text(m.name)
                .foregroundStyle(Color(white: 0.62))
            Spacer()
            Text(feetInchString(m.meters))
                .fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.horizontal, 22)
        .padding(.vertical, 5)
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
