import SwiftUI

@main
struct CainApp: App {
    @StateObject private var tunnel = TunnelController.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CainRuntime.registerBackground()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(tunnel)
                .preferredColorScheme(.dark)
                .task { await tunnel.load() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // .inactive (Control Center, a system alert) still has the window on screen.
            CainRuntime.shared.setForeground(phase != .background)
        }
    }
}
