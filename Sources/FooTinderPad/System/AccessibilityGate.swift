import AppKit
import ApplicationServices

final class AccessibilityGate {
    enum State: Equatable { case granted, denied }

    private(set) var state: State
    private var pollTimer: Timer?

    /// Called on the main queue every time `state` transitions.
    var onStateChange: ((State) -> Void)?

    init() {
        self.state = AXIsProcessTrusted() ? .granted : .denied
    }

    /// If denied, shows an alert that links to System Settings and quits the app.
    func checkAndPromptIfNeeded() {
        guard state == .denied else { return }

        let alert = NSAlert()
        alert.messageText = "FooTinderPad needs Accessibility permission"
        alert.informativeText = """
        FooTinderPad relays controller input as mouse and keyboard events.
        macOS requires Accessibility access to do this.

        Grant access in System Settings → Privacy & Security → Accessibility,
        then re-launch FooTinderPad.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        NSApp.terminate(nil)
    }

    /// Starts a 5 s timer that picks up grant changes made while running.
    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let newState: State = AXIsProcessTrusted() ? .granted : .denied
            if newState != self.state {
                self.state = newState
                self.onStateChange?(newState)
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
