import AppKit
import SwiftUI
import SharedModels
import SharedUtilities

enum ConnectionControlsPresentation: String, CaseIterable, Identifiable {
    static let storageKey = "client.connectionControls.presentation"
    /// Native window title-bar toolbar (default). Stored as `floatingPill` for
    /// backwards compatibility with existing AppStorage values.
    case floatingPill
    case menuBarItem

    var id: Self { self }

    var settingsLabel: String {
        switch self {
        case .floatingPill: return "Window Toolbar"
        case .menuBarItem: return "Menu Bar Item"
        }
    }
}

@main
struct MacClientApp: App {
    @StateObject private var environment = MacClientEnvironmentFactory.make()
    @StateObject private var menuBarController = MacMenuBarController()
    @AppStorage(ConnectionControlsPresentation.storageKey)
    private var controlsPresentation = ConnectionControlsPresentation.floatingPill.rawValue

    private static var versionString: String {
        "Version " + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
    }

    var body: some Scene {
        WindowGroup {
            MacShellView(environment: environment)
                .frame(minWidth: 760, minHeight: 480)
                .background(MacClientWindowConfigurator())
                .task {
                    menuBarController.configure(environment: environment)
                    menuBarController.setEnabled(
                        controlsPresentation == ConnectionControlsPresentation.menuBarItem.rawValue
                    )
                }
                .onChange(of: controlsPresentation) { newValue in
                    menuBarController.setEnabled(
                        newValue == ConnectionControlsPresentation.menuBarItem.rawValue
                    )
                }
                .vampSplashWindow(.macClient(version: Self.versionString))
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        // Sensible first-launch size — opens composed, not at the bare minimum
        // or some oversized restored frame.
        .defaultSize(width: 860, height: 600)
        .commands {
            // Session verbs belong in their own menu, not buried under the app
            // app menu — and it leaves room for future actions.
            CommandMenu("Session") {
                MacRefreshCommand(environment: environment)
                Divider()
                MacDisconnectCommand(environment: environment)
            }
            CommandMenu("View") {
                MacDisplayModeCommands()
            }
        }

        Settings {
            MacSettingsScreen(environment: environment)
        }
    }
}

/// Keeps the SwiftUI content window transparent and extends the native clear
/// surface through AppKit's unified title bar.
private struct MacClientWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        // Keep a real title bar / toolbar so session controls stay readable and
        // clickable in the window chrome (not overlaid on the remote video).
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.toolbar?.showsBaselineSeparator = true
    }
}

/// Menu command to rescan the local network for hosts (⌘R). Disabled while a
/// session is live, where the hosts list isn't on screen.
private struct MacRefreshCommand: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var coordinator: ClientSessionCoordinator

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.coordinator = environment.sessionCoordinator
    }

    var body: some View {
        Button("Refresh Hosts") {
            Task { await environment.sharedHostsViewModel.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(coordinator.phase == .receiving || coordinator.phase == .waitingForMedia)
    }
}

/// Menu command to end the active session (⇧⌘D).
private struct MacDisconnectCommand: View {
    @ObservedObject var environment: ClientAppEnvironment
    @ObservedObject private var coordinator: ClientSessionCoordinator

    init(environment: ClientAppEnvironment) {
        self.environment = environment
        self.coordinator = environment.sessionCoordinator
    }

    var body: some View {
        Button("Disconnect from Host") {
            Task { await coordinator.endSession() }
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .disabled(coordinator.phase == .idle)
    }
}

/// View-menu display sizing. Same AppStorage key the session toolbar uses, so
/// the menu bar and the Fit Display button stay in sync.
private struct MacDisplayModeCommands: View {
    @AppStorage("client.displayMode") private var displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue

    var body: some View {
        Button("Fit Display") {
            displayModeRaw = DisplayMappingEngine.DisplayMode.fitDisplay.rawValue
        }
        .keyboardShortcut("0", modifiers: .command)
        Button("Fill Window") {
            displayModeRaw = DisplayMappingEngine.DisplayMode.fillScreen.rawValue
        }
        .keyboardShortcut("1", modifiers: .command)
        Button("Actual Size") {
            displayModeRaw = DisplayMappingEngine.DisplayMode.actualSize.rawValue
        }
        .keyboardShortcut("2", modifiers: .command)
    }
}
