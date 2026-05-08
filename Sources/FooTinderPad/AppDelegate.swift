import AppKit
import GameController
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "AppDelegate")
    private let menuBar = MenuBar()
    private let accessibility = AccessibilityGate()
    private let launchAtLogin = LaunchAtLogin()
    private let battery = BatteryMonitor()
    private let configManager = ConfigManager()
    private let sink: EventSink = CGEventSink()
    private lazy var key = KeySynthesizer(sink: sink)
    private lazy var mouse = MouseSynthesizer(sink: sink)
    private lazy var dispatcher = InputDispatcher(
        config: { [weak self] in self?.configManager.current ?? .empty },
        key: key,
        mouse: mouse
    )
    private lazy var controllers = ControllerManager(dispatcher: dispatcher)
    private lazy var tickLoop = TickLoop(dispatcher: dispatcher)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hash = Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String ?? "?"
        let date = Bundle.main.object(forInfoDictionaryKey: "GitCommitDate") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        log.info("launching: build=\(build, privacy: .public) commit=\(hash, privacy: .public) date=\(date, privacy: .public)")

        installEditMenu()
        installMenuBar()

        launchAtLogin.onStateChange = { [weak self] state in
            self?.menuBar.setLaunchAtLogin(state: state)
        }
        menuBar.setLaunchAtLogin(state: launchAtLogin.state)

        configManager.onSwap = { [weak self] _ in
            self?.dispatcher.drainHeldInputs()
        }
        configManager.start()

        accessibility.onStateChange = { [weak self] state in
            self?.refreshMenuBarState()
            if state == .denied { self?.dispatcher.drainHeldInputs() }
            // Re-evaluate the bind: if access was revoked, unbind immediately
            // so a pending timer tick cannot resurrect the suffix.
            self?.rebindBattery()
        }
        accessibility.checkAndPromptIfNeeded() // terminates if denied
        accessibility.startPolling()

        battery.onChange = { [weak self] suffix in
            self?.menuBar.setBatterySuffix(suffix)
        }
        controllers.onActiveChanged = { [weak self] _ in
            self?.rebindBattery()
            self?.refreshMenuBarState()
        }
        controllers.start()
        tickLoop.start()

        refreshMenuBarState()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickLoop.stop()
        controllers.stop()
        configManager.stop()
        accessibility.stop()
        battery.stop()
    }

    // MARK: - menu bar wiring

    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        NSApp.mainMenu = mainMenu
    }

    private func installMenuBar() {
        menuBar.install()
        menuBar.onReloadConfig = { [weak self] in self?.configManager.reloadNow() }
        menuBar.onRevealConfig = {
            NSWorkspace.shared.activateFileViewerSelecting([Paths.configURL])
        }
        menuBar.onOpenConsole = {
            // Console.app's search field doesn't recognize "subsystem:..." prefix syntax;
            // instead, the user pastes the bare bundle id and picks "Subsystem" from the
            // dropdown that appears. So copy just the id, not a pre-formatted predicate.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString("com.purefuncinc.FooTinderPad", forType: .string)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
        }
        menuBar.onAbout = { [weak self] in self?.showAboutPanel() }
        menuBar.onQuit  = { NSApp.terminate(nil) }
        menuBar.onToggleLaunchAtLogin = { [weak self] in self?.launchAtLogin.handleClick() }
        menuBar.onMenuWillOpen = { [weak self] in
            self?.launchAtLogin.refresh()
            self?.battery.refresh()
        }
    }

    private func rebindBattery() {
        let target: GCController? = (accessibility.state == .granted) ? controllers.active : nil
        battery.bind(controller: target)
    }

    private func refreshMenuBarState() {
        switch accessibility.state {
        case .denied:
            menuBar.setIcon(.unauthorized)
            menuBar.setStatusLine("⚠ Accessibility not granted")
        case .granted:
            if let c = controllers.active {
                menuBar.setIcon(.operational)
                menuBar.setStatusLine(c.vendorName ?? "Controller connected")
            } else {
                menuBar.setIcon(.idle)
                menuBar.setStatusLine("No controller")
            }
        }
    }

    private func showAboutPanel() {
        let hash = Bundle.main.object(forInfoDictionaryKey: "GitCommitHash") as? String ?? ""
        let date = Bundle.main.object(forInfoDictionaryKey: "GitCommitDate") as? String ?? ""
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        let detail = [hash, date].filter { !$0.isEmpty }.joined(separator: ",")
        if !detail.isEmpty {
            options[.applicationVersion] = detail
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
