import SwiftUI

#if VAMP_TERMINAL_HOST && os(macOS)
@main
struct VampTerminalHostApp: App {
    @StateObject private var environment = HostAppEnvironment.placeholder(mode: .terminalOnly)

    var body: some Scene {
        WindowGroup(id: "main") {
            VampTerminalHostShellView(environment: environment)
        }
        .windowResizability(.contentSize)
    }
}
#endif
