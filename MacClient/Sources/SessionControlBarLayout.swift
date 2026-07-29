import AppKit
import CoreGraphics
import SwiftUI

/// Layout constants for the floating session control bar.
enum SessionControlBarMetrics {
    static let barHeight: CGFloat = 56
    static let pillHeight: CGFloat = 44
    static let minimumInteractiveSize: CGFloat = 44
    static let horizontalPadding: CGFloat = 14
    static let comfortInset: CGFloat = 14
    /// Extra gap above the Dock / screen edge so the bar is not visually attached.
    static let dockGap: CGFloat = 12
    static let expandedSectionSpacing: CGFloat = 8
}

enum SessionControlBarLayoutMode: Equatable {
    case wide
    case compact
    case iconOnly
}

/// Pure layout helpers used by the session control bar and its unit tests.
enum SessionControlBarLayout {
    /// Bottom padding that keeps the bar inside the usable screen area above the Dock.
    ///
    /// - Parameters:
    ///   - windowFrame: The hosting window frame in screen coordinates.
    ///   - visibleFrame: `NSScreen.visibleFrame` for the screen containing the window.
    static func bottomInset(
        windowFrame: CGRect,
        visibleFrame: CGRect,
        comfortInset: CGFloat = SessionControlBarMetrics.comfortInset,
        dockGap: CGFloat = SessionControlBarMetrics.dockGap
    ) -> CGFloat {
        let dockOverlap = max(0, visibleFrame.minY - windowFrame.minY)
        return comfortInset + dockOverlap + dockGap
    }

    static func layoutMode(availableWidth: CGFloat) -> SessionControlBarLayoutMode {
        if availableWidth >= 680 { return .wide }
        if availableWidth >= 480 { return .compact }
        return .iconOnly
    }

    /// Height of the AppKit stream surface that must not receive pointer events.
    static func chromeExclusionHeight(
        bottomInset: CGFloat,
        isExpanded: Bool,
        expandedContentHeight: CGFloat,
        pillHeight: CGFloat = SessionControlBarMetrics.pillHeight,
        sectionSpacing: CGFloat = SessionControlBarMetrics.expandedSectionSpacing
    ) -> CGFloat {
        let expandedStack = isExpanded ? expandedContentHeight + sectionSpacing : 0
        return bottomInset + pillHeight + expandedStack
    }
}

/// Tracks the hosting window against `NSScreen.visibleFrame` and publishes a bottom inset.
struct MacSessionScreenInsetsReader: NSViewRepresentable {
    @Binding var bottomInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(bottomInset: $bottomInset) }

    func makeNSView(context: Context) -> InsetTrackingView {
        let view = InsetTrackingView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: InsetTrackingView, context: Context) {
        context.coordinator.bottomInset = $bottomInset
        nsView.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window: window)
        }
        context.coordinator.observe(window: nsView.window)
    }

    static func dismantleNSView(_ nsView: InsetTrackingView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator {
        var bottomInset: Binding<CGFloat>
        private var observers: [NSObjectProtocol] = []
        private weak var observedWindow: NSWindow?

        init(bottomInset: Binding<CGFloat>) {
            self.bottomInset = bottomInset
        }

        func refresh(window: NSWindow?) {
            guard let window else { return }
            let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
            let visible = screen?.visibleFrame ?? window.frame
            let inset = SessionControlBarLayout.bottomInset(
                windowFrame: window.frame,
                visibleFrame: visible
            )
            if abs(bottomInset.wrappedValue - inset) > 0.5 {
                bottomInset.wrappedValue = inset
            }
        }

        func observe(window: NSWindow?) {
            if observedWindow === window { return }
            teardown()
            observedWindow = window
            guard let window else { return }
            let center = NotificationCenter.default
            let workspace = NSWorkspace.shared.notificationCenter
            observers = [
                center.addObserver(
                    forName: NSWindow.didMoveNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.refresh(window: window) },
                center.addObserver(
                    forName: NSWindow.didResizeNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.refresh(window: window) },
                center.addObserver(
                    forName: NSWindow.didChangeScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.refresh(window: window) },
                center.addObserver(
                    forName: NSWindow.didEnterFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.refresh(window: window) },
                center.addObserver(
                    forName: NSWindow.didExitFullScreenNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in self?.refresh(window: window) },
                workspace.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.refresh(window: window) },
            ]
            refresh(window: window)
        }

        func teardown() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            observedWindow = nil
        }
    }

    final class InsetTrackingView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}

private struct SessionControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    /// Reports the measured height of expanded session controls to the parent.
    func reportSessionControlsHeight() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: SessionControlsHeightKey.self, value: proxy.size.height)
            }
        }
    }

    func onSessionControlsHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        onPreferenceChange(SessionControlsHeightKey.self, perform: action)
    }
}
