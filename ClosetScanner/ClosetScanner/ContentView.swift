//
//  ContentView.swift
//  ClosetScanner
//

import SwiftUI
import RoomPlan

struct ContentView: View {
    private let isSupported = RoomCaptureSession.isSupported

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "door.sliding.left.hand.closed")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)

                Text("Closet Scanner")
                    .font(.largeTitle.bold())

                Text("Scan a closet with the LiDAR camera, hide its contents, and measure the empty space.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                Label(
                    isSupported ? "RoomPlan supported" : "RoomPlan not supported on this device",
                    systemImage: isSupported ? "checkmark.circle.fill" : "xmark.octagon.fill"
                )
                .foregroundStyle(isSupported ? Color.green : Color.red)
                .font(.callout.weight(.medium))

                Spacer()

                Button("Start Closet Scan") {
                    // Phase 2: present the RoomPlan scan screen
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        tip("Point into the closet, not the room behind you")
                        tip("Capture the back corners first, then sweep both side walls")
                        tip("Aim up at both ceiling levels and the soffit edges")
                        tip("Move slowly and keep corners in view")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Scanning tips", systemImage: "lightbulb")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
        }
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}

#Preview {
    ContentView()
}
