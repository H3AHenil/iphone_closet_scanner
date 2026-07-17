//
//  StartView.swift
//  ClosetScanner
//
//  Home screen: asks the one question that shapes the capture order (soffit?)
//  and starts the scan.
//

import SwiftUI

struct StartView: View {
    let onStart: (_ hasSoffit: Bool) -> Void
    @State private var hasSoffit: Bool?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer()

                appMark

                Text("Closet Scanner")
                    .font(.system(.largeTitle, design: .rounded).bold())

                Text("Scan a reach-in closet with LiDAR, see it empty, and get dimensions to the nearest 1/16″.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 36)

                Spacer()

                soffitCard

                if !CaptureController.lidarAvailable {
                    Label("This device has no LiDAR — scanning won't work", systemImage: "xmark.octagon.fill")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }

                Button {
                    onStart(hasSoffit ?? false)
                } label: {
                    Text("Start Scan")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .disabled(hasSoffit == nil)

                Text(orderCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer().frame(height: 12)
            }
        }
    }

    private var appMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 88, height: 88)
                .shadow(color: .blue.opacity(0.3), radius: 14, y: 6)
            Image(systemName: "door.sliding.left.hand.closed")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private var soffitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Does the closet have a soffit?")
                .font(.headline)
            Text("A boxed-in drop below the ceiling, usually above the door. If yes, it gets measured first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                choice(true, "Yes")
                choice(false, "No")
            }
        }
        .padding(16)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
    }

    private func choice(_ value: Bool, _ label: String) -> some View {
        Button {
            hasSoffit = value
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(hasSoffit == value ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(.quaternarySystemFill)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(hasSoffit == value ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var orderCaption: String {
        switch hasSoffit {
        case true: "Capture order: soffit → interior → door"
        case false: "Capture order: interior → door"
        default: "Answer above to begin"
        }
    }
}
