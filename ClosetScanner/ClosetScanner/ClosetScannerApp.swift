//
//  ClosetScannerApp.swift
//  ClosetScanner
//
//  Created by Henil Agrawal on 2026-07-15.
//

import SwiftUI

@main
struct ClosetScannerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @State private var scanning = false
    @State private var hasSoffit = false

    var body: some View {
        ZStack {
            if scanning {
                ScanView(hasSoffit: hasSoffit) {
                    withAnimation(.easeInOut(duration: 0.25)) { scanning = false }
                }
                .transition(.opacity)
            } else {
                StartView { soffit in
                    hasSoffit = soffit
                    withAnimation(.easeInOut(duration: 0.25)) { scanning = true }
                }
                .transition(.opacity)
            }
        }
    }
}
