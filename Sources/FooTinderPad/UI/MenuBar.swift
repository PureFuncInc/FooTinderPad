import AppKit

final class MenuBar: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusLineItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var menu: NSMenu!

    var onReloadConfig: (() -> Void)?
    var onRevealConfig: (() -> Void)?
    var onOpenConsole: (() -> Void)?
    var onAbout: (() -> Void)?
    var onQuit: (() -> Void)?
    var onToggleLaunchAtLogin: (() -> Void)?
    var onMenuWillOpen: (() -> Void)?

    enum IconState { case operational, idle, unauthorized }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(.idle)

        menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(Self.makeMenuItem(
            title: "About FooTinderPad",
            systemImage: "info.circle",
            target: self,
            action: #selector(_about)
        ))
        menu.addItem(.separator())

        statusLineItem = NSMenuItem(title: "No controller", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        let configLogsItem = Self.makeMenuItem(title: "Config & Logs", systemImage: "folder")
        let configLogsSubmenu = NSMenu()
        configLogsSubmenu.addItem(Self.makeMenuItem(
            title: "Reload Config",
            systemImage: "arrow.clockwise",
            target: self,
            action: #selector(_reload),
            keyEquivalent: "r"
        ))
        configLogsSubmenu.addItem(Self.makeMenuItem(
            title: "Reveal Config in Finder",
            systemImage: "folder",
            target: self,
            action: #selector(_reveal)
        ))
        configLogsSubmenu.addItem(Self.makeMenuItem(
            title: "Open Console.app (paste, then pick Subsystem)",
            systemImage: "text.magnifyingglass",
            target: self,
            action: #selector(_openConsole)
        ))
        menu.addItem(configLogsItem)
        menu.setSubmenu(configLogsSubmenu, for: configLogsItem)

        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(_toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        menu.addItem(Self.makeMenuItem(
            title: "Quit",
            systemImage: "power",
            target: self,
            action: #selector(_quit),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    private static func makeMenuItem(
        title: String,
        systemImage: String,
        target: AnyObject? = nil,
        action: Selector? = nil,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        return item
    }

    private static func warningImage() -> NSImage? {
        let palette = NSImage.SymbolConfiguration(paletteColors: [.systemYellow])
        let size = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Needs attention")?
            .withSymbolConfiguration(size.applying(palette))
    }

    func setStatusLine(_ text: String) {
        statusLineItem.title = text
    }

    func setLaunchAtLogin(state: LaunchAtLoginState) {
        switch state {
        case .enabled:
            launchAtLoginItem.state = .on
            launchAtLoginItem.image = nil
            launchAtLoginItem.toolTip = nil
        case .disabled:
            launchAtLoginItem.state = .off
            launchAtLoginItem.image = nil
            launchAtLoginItem.toolTip = nil
        case .requiresApproval:
            launchAtLoginItem.state = .off
            launchAtLoginItem.image = Self.warningImage()
            launchAtLoginItem.toolTip = "Approve in System Settings → General → Login Items"
        case .failed(let msg):
            launchAtLoginItem.state = .off
            launchAtLoginItem.image = Self.warningImage()
            launchAtLoginItem.toolTip = msg
        }
    }

    func setIcon(_ state: IconState) {
        guard let button = statusItem?.button else { return }
        let size = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular, scale: .medium)
        let base = NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)
        switch state {
        case .operational:
            // template = true so macOS auto-tints to the menu bar foreground colour
            // (black in light mode, white in dark mode) — full contrast against the bar.
            let image = base?.withSymbolConfiguration(size)
            image?.isTemplate = true
            button.image = image
        case .idle:
            let palette = NSImage.SymbolConfiguration(paletteColors: [.systemGray])
            let image = base?.withSymbolConfiguration(size.applying(palette))
            image?.isTemplate = false
            button.image = image
        case .unauthorized:
            let palette = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = base?.withSymbolConfiguration(size.applying(palette))
            image?.isTemplate = false
            button.image = image
        }
        button.title = ""
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        onMenuWillOpen?()
    }

    @objc private func _reload() { onReloadConfig?() }
    @objc private func _reveal() { onRevealConfig?() }
    @objc private func _openConsole() { onOpenConsole?() }
    @objc private func _about() { onAbout?() }
    @objc private func _quit()  { onQuit?() }
    @objc private func _toggleLaunchAtLogin() { onToggleLaunchAtLogin?() }
}
