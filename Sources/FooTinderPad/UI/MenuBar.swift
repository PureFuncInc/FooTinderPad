import AppKit

final class MenuBar {
    private var statusItem: NSStatusItem!
    private var statusLineItem: NSMenuItem!
    private var menu: NSMenu!

    var onReloadConfig: (() -> Void)?
    var onRevealConfig: (() -> Void)?
    var onAbout: (() -> Void)?
    var onQuit: (() -> Void)?

    enum IconState { case operational, idle, unauthorized }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(.idle)

        menu = NSMenu()
        menu.autoenablesItems = false

        statusLineItem = NSMenuItem(title: "No controller", action: nil, keyEquivalent: "")
        statusLineItem.isEnabled = false
        menu.addItem(statusLineItem)
        menu.addItem(.separator())

        let reload = NSMenuItem(title: "Reload Config", action: #selector(_reload), keyEquivalent: "r")
        reload.target = self
        menu.addItem(reload)

        let reveal = NSMenuItem(title: "Reveal Config in Finder", action: #selector(_reveal), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "About FooTinderPad", action: #selector(_about), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit", action: #selector(_quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func setStatusLine(_ text: String) {
        statusLineItem.title = text
    }

    func setIcon(_ state: IconState) {
        guard let button = statusItem?.button else { return }
        let color: NSColor
        switch state {
        case .operational: color = .white
        case .idle:        color = .gray
        case .unauthorized: color = .systemRed
        }
        let size = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular, scale: .medium)
        let palette = NSImage.SymbolConfiguration(paletteColors: [color])
        let cfg = size.applying(palette)
        let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        image?.isTemplate = false
        button.image = image
        button.title = ""
    }

    @objc private func _reload() { onReloadConfig?() }
    @objc private func _reveal() { onRevealConfig?() }
    @objc private func _about() { onAbout?() }
    @objc private func _quit()  { onQuit?() }
}
