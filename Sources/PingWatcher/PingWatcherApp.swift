import SwiftUI
import AppKit

@main
struct PingWatcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        WindowGroup("PingWatch") {
            DashboardView()
                .environmentObject(monitor)
                .onAppear {
                    monitor.start(hostsPath: HostFile.resolvePath(CommandLine.arguments))
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1020, height: 660)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Palette matching the mockup (GitHub-dark-ish).
struct Palette {
    static let shared = Palette()
    let bg = Color(hex: 0x0D1117)
    let panel = Color(hex: 0x161B22)
    let border = Color(hex: 0x2D333B)
    let text = Color(hex: 0xC9D1D9)
    let dim = Color(hex: 0x8B949E)
    let green = Color(hex: 0x3FB950)
    let red = Color(hex: 0xF85149)
    let yellow = Color(hex: 0xD29922)
    let line = Color(hex: 0x58A6FF)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
