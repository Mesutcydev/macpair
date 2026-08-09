import SwiftUI

@main
struct VampTerminalApp: App {
    @StateObject private var environment: ClientAppEnvironment

    init() {
        _environment = StateObject(
            wrappedValue: ClientAppEnvironment.makeDefault(
                clientName: "Vamp Terminal",
                supportsTerminalOnlyHosts: true,
                clientProductRole: .terminal
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            VampTerminalHomeView(environment: environment)
        }
    }
}
