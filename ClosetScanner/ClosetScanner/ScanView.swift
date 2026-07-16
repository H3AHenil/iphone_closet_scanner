//
//  ScanView.swift
//  ClosetScanner
//
//  AR camera + HUD: reticle, surface chips, capture button, live measurements.
//

import SwiftUI
import RealityKit
import ARKit

struct ScanView: View {
    @StateObject private var controller = CaptureController()
    @State private var showResetConfirm = false
    @State private var calibrateTarget: Measurement?
    @State private var calibrateText = ""

    var body: some View {
        ZStack {
            ARViewContainer(controller: controller)
                .ignoresSafeArea()

            reticle

            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomPanel
            }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .confirmationDialog("Clear all captured surfaces?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Clear scan", role: .destructive) { controller.reset() }
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

    // MARK: Top

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(CaptureController.lidarAvailable ? controller.status : "This device has no LiDAR — scanning unavailable")
                    .font(.footnote.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                VStack(spacing: 10) {
                    hudButton(controller.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                              tint: controller.torchOn ? .yellow : .white) {
                        controller.torchOn.toggle()
                    }
                    hudButton("trash", tint: .white) { showResetConfirm = true }
                }
            }
            if controller.calibration != 1 {
                HStack {
                    Text(String(format: "cal ×%.4f", controller.calibration))
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .contextMenu {
                            Button("Reset calibration", role: .destructive) { controller.resetCalibration() }
                        }
                    Spacer()
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func hudButton(_ systemName: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: Reticle

    private var reticle: some View {
        let side = 90 + CGFloat(controller.target.windowFraction) * 320
        return RoundedRectangle(cornerRadius: 14)
            .strokeBorder(controller.target.color, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
            .frame(width: side, height: side)
            .opacity(controller.captureProgress == nil ? 0.9 : 0.4)
            .animation(.easeInOut(duration: 0.2), value: controller.target)
            .allowsHitTesting(false)
    }

    // MARK: Bottom

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            if !controller.measurements.isEmpty { measurementCard }
            chipRow
            captureButton
        }
        .padding(.bottom, 14)
    }

    private var chipRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SurfaceLabel.allCases) { label in
                        chip(label)
                            .id(label)
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
                Circle().fill(label.color).frame(width: 8, height: 8)
                Text(label.short).font(.footnote.weight(.medium))
                if captured {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(isTarget ? label.color : .clear, lineWidth: 2))
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
        Button(action: controller.beginCapture) {
            ZStack {
                Circle()
                    .fill(controller.trackingNormal ? Color.white : Color.gray.opacity(0.5))
                    .frame(width: 68, height: 68)
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 80, height: 80)
                if let p = controller.captureProgress {
                    Circle()
                        .trim(from: 0, to: p)
                        .stroke(controller.target.color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 80, height: 80)
                }
                Image(systemName: "viewfinder")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.black.opacity(controller.trackingNormal ? 0.8 : 0.3))
            }
        }
        .disabled(!controller.trackingNormal || controller.captureProgress != nil)
    }

    private var measurementCard: some View {
        VStack(spacing: 0) {
            ForEach(controller.measurements) { m in
                Button { calibrateTarget = m } label: { measurementRow(m) }
                    .buttonStyle(.plain)
                if m.id != controller.measurements.last?.id { Divider() }
            }
        }
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
