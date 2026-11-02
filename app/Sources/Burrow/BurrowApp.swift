import AppKit
import SwiftUI

@main
struct BurrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Burrow") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.rawValue) { model.tab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A previous run may have been killed mid-clean: drop any leftover
        // temporary exclusions so the user's whitelist is exactly theirs.
        Whitelist.restore()
        PlanetTexture.prewarm()
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Whitelist.restore()
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var tab: AppTab = .clean
    @Published var cliVersion: String?
    @Published var cliMissing = false

    let clean = CleanModel()
    let apps = AppsModel()
    let optimize = OptimizeModel()
    let analyze = AnalyzeModel()
    let status = StatusModel()

    init() {
        cliMissing = MoleCLI.executableURL == nil
        if let start = ProcessInfo.processInfo.environment["BURROW_TAB"],
           let initial = AppTab.allCases.first(where: { $0.rawValue.lowercased() == start.lowercased() }) {
            tab = initial
        }
        Task { cliVersion = await MoleCLI.version() }
    }
}
