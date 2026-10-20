import SwiftUI

@main
struct CainApp: App {
    @StateObject private var tunnel = TunnelController.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(tunnel)
                .preferredColorScheme(.dark)
                .task { await tunnel.load() }
        }
    }
}
