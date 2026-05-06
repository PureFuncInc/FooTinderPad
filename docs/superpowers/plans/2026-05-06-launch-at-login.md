# Launch at Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A checkable "Launch at Login" item in the menu bar that registers/unregisters the app via `SMAppService.mainApp` and surfaces a yellow warning triangle when the OS reports `.requiresApproval` or a registration failure.

**Architecture:** A new `LaunchAtLogin` class (mirrors `AccessibilityGate`'s shape — owns its own state, exposes `onStateChange`, no UI deps) wraps `SMAppService.mainApp`. `MenuBar` gains an item plus an `NSMenuDelegate.menuWillOpen` hook that triggers `refresh()` so external changes (e.g. user disabling in System Settings) sync into the UI on next menu open. Click behavior is state-aware: `.requiresApproval` and `.failed` route to `SMAppService.openSystemSettingsLoginItems()` instead of re-trying register/unregister, so the user can always make progress.

**Tech Stack:** Swift 5.9+, AppKit, ServiceManagement.framework (`SMAppService`), XCTest. macOS 13+.

**Spec:** `docs/superpowers/specs/2026-05-06-launch-at-login-design.md`

---

### Task 1: Create `LaunchAtLogin` types and pure `action(for:)` helper (TDD)

**Files:**
- Create: `Sources/FooTinderPad/System/LaunchAtLogin.swift`
- Create: `Tests/FooTinderPadTests/LaunchAtLoginTests.swift`

This task locks in the type contract used everywhere else. The pure `action(for:)` helper is the only piece of `LaunchAtLogin` we unit-test (the rest wraps `SMAppService` and is exercised by manual smoke test, matching `AccessibilityGate`'s style). Subsequent tasks expand the same `LaunchAtLogin` class with the system-wrapper bits.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FooTinderPadTests/LaunchAtLoginTests.swift`:

```swift
import XCTest
@testable import FooTinderPad

final class LaunchAtLoginTests: XCTestCase {
    func testActionWhenDisabled() {
        XCTAssertEqual(LaunchAtLogin.action(for: .disabled), .enable)
    }

    func testActionWhenEnabled() {
        XCTAssertEqual(LaunchAtLogin.action(for: .enabled), .disable)
    }

    func testActionWhenRequiresApproval() {
        XCTAssertEqual(LaunchAtLogin.action(for: .requiresApproval), .openSystemSettings)
    }

    func testActionWhenFailed() {
        XCTAssertEqual(LaunchAtLogin.action(for: .failed("any error")), .openSystemSettings)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LaunchAtLoginTests`
Expected: build error — `cannot find 'LaunchAtLogin' in scope` / `cannot find type 'LaunchAtLoginState' in scope`.

- [ ] **Step 3: Create the minimal types and helper**

Create `Sources/FooTinderPad/System/LaunchAtLogin.swift`:

```swift
import Foundation

enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case failed(String)
}

enum LaunchAtLoginAction: Equatable {
    case enable
    case disable
    case openSystemSettings
}

final class LaunchAtLogin {
    static func action(for state: LaunchAtLoginState) -> LaunchAtLoginAction {
        switch state {
        case .disabled:                      return .enable
        case .enabled:                       return .disable
        case .requiresApproval, .failed:     return .openSystemSettings
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LaunchAtLoginTests`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FooTinderPad/System/LaunchAtLogin.swift Tests/FooTinderPadTests/LaunchAtLoginTests.swift
git commit -m "feat: add LaunchAtLogin state types and pure action() helper"
```

---

### Task 2: Wrap `SMAppService.mainApp` in `LaunchAtLogin`

**Files:**
- Modify: `Sources/FooTinderPad/System/LaunchAtLogin.swift`

Add the instance-side: `state` property, `refresh()`, `handleClick()`, and `onStateChange` callback, plus the private `SMAppService.Status` → `LaunchAtLoginState` mapping. No new tests — the spec deliberately treats this layer the same way `AccessibilityGate` is treated (system API + thin glue, exercised by manual smoke test, not unit-tested to avoid polluting LaunchServices in CI).

- [ ] **Step 1: Replace `LaunchAtLogin.swift` with the full version**

Overwrite `Sources/FooTinderPad/System/LaunchAtLogin.swift` with:

```swift
import AppKit
import ServiceManagement
import os

enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case failed(String)
}

enum LaunchAtLoginAction: Equatable {
    case enable
    case disable
    case openSystemSettings
}

final class LaunchAtLogin {
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "LaunchAtLogin")
    private(set) var state: LaunchAtLoginState

    /// Called on the main queue every time `state` transitions.
    var onStateChange: ((LaunchAtLoginState) -> Void)?

    init() {
        self.state = Self.readState()
        log.info("initial launch-at-login state: \(String(describing: self.state), privacy: .public)")
    }

    /// Re-reads `SMAppService.mainApp.status`. Called from `NSMenuDelegate.menuWillOpen`
    /// so external changes (e.g. user toggling in System Settings) sync on next menu open.
    func refresh() {
        let next = Self.readState()
        guard next != state else { return }
        log.info("launch-at-login state changed: \(String(describing: next), privacy: .public)")
        state = next
        onStateChange?(next)
    }

    /// State-aware click dispatch — see `LaunchAtLogin.action(for:)` for the routing rules.
    /// `.requiresApproval` / `.failed` route to System Settings because re-`register()`-ing
    /// before the user approves is a no-op and would leave them stuck.
    func handleClick() {
        switch Self.action(for: state) {
        case .enable:
            do {
                try SMAppService.mainApp.register()
            } catch {
                log.error("register failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                onStateChange?(state)
                return
            }
            refresh()

        case .disable:
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                log.error("unregister failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
                onStateChange?(state)
                return
            }
            refresh()

        case .openSystemSettings:
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    static func action(for state: LaunchAtLoginState) -> LaunchAtLoginAction {
        switch state {
        case .disabled:                      return .enable
        case .enabled:                       return .disable
        case .requiresApproval, .failed:     return .openSystemSettings
        }
    }

    private static func readState() -> LaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .notRegistered:     return .disabled
        case .requiresApproval:  return .requiresApproval
        case .notFound:          return .failed("login item not found")
        @unknown default:        return .failed("unknown SMAppService status")
        }
    }
}
```

- [ ] **Step 2: Re-run unit tests to confirm Task 1's tests still pass**

Run: `swift test --filter LaunchAtLoginTests`
Expected: 4 tests pass (the pure helper's signature is unchanged).

- [ ] **Step 3: Build the full target to confirm it compiles**

Run: `swift build`
Expected: build succeeds. (No call sites use the new instance API yet — that comes in Task 4.)

- [ ] **Step 4: Commit**

```bash
git add Sources/FooTinderPad/System/LaunchAtLogin.swift
git commit -m "feat: wrap SMAppService.mainApp in LaunchAtLogin"
```

---

### Task 3: Add menu item, `NSMenuDelegate` conformance, and state renderer to `MenuBar`

**Files:**
- Modify: `Sources/FooTinderPad/UI/MenuBar.swift`

`MenuBar` today is a plain `final class` with no superclass. `NSMenuDelegate` requires `NSObjectProtocol`, so we make it inherit from `NSObject`. The new menu item sits between `Config & Logs` and `Quit`, in its own separator-bounded group. Two new callbacks (`onToggleLaunchAtLogin`, `onMenuWillOpen`) and one new public method (`setLaunchAtLogin(state:)`) let `AppDelegate` wire it up.

- [ ] **Step 1: Replace `MenuBar.swift` with the updated version**

Overwrite `Sources/FooTinderPad/UI/MenuBar.swift` with:

```swift
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
        let base = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
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
```

- [ ] **Step 2: Build to confirm it compiles**

Run: `swift build`
Expected: build succeeds. The new `setLaunchAtLogin(state:)` API and callbacks have no callers yet — that's wired up in Task 4.

- [ ] **Step 3: Commit**

```bash
git add Sources/FooTinderPad/UI/MenuBar.swift
git commit -m "feat: add Launch at Login menu item and NSMenuDelegate hook"
```

---

### Task 4: Wire `LaunchAtLogin` into `AppDelegate`

**Files:**
- Modify: `Sources/FooTinderPad/AppDelegate.swift`

Instantiate `LaunchAtLogin` as a stored property (matching the pattern of `accessibility`, `configManager`), wire its `onStateChange` to `MenuBar.setLaunchAtLogin(state:)`, push the initial state once after `installMenuBar()`, and route the menu callbacks.

- [ ] **Step 1: Add the stored property**

In `Sources/FooTinderPad/AppDelegate.swift`, add a new line after the existing `private let accessibility = AccessibilityGate()` (around line 8):

```swift
    private let launchAtLogin = LaunchAtLogin()
```

The block of stored properties should now read:

```swift
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "AppDelegate")
    private let menuBar = MenuBar()
    private let accessibility = AccessibilityGate()
    private let launchAtLogin = LaunchAtLogin()
    private let configManager = ConfigManager()
    private let sink: EventSink = CGEventSink()
```

- [ ] **Step 2: Add the menu callbacks in `installMenuBar`**

Inside `installMenuBar()`, append two new lines after the existing `menuBar.onQuit = { NSApp.terminate(nil) }` (around line 89):

```swift
        menuBar.onToggleLaunchAtLogin = { [weak self] in self?.launchAtLogin.handleClick() }
        menuBar.onMenuWillOpen = { [weak self] in self?.launchAtLogin.refresh() }
```

So the bottom of `installMenuBar()` reads:

```swift
        menuBar.onAbout = { [weak self] in self?.showAboutPanel() }
        menuBar.onQuit  = { NSApp.terminate(nil) }
        menuBar.onToggleLaunchAtLogin = { [weak self] in self?.launchAtLogin.handleClick() }
        menuBar.onMenuWillOpen = { [weak self] in self?.launchAtLogin.refresh() }
```

- [ ] **Step 3: Wire `onStateChange` and push initial state in `applicationDidFinishLaunching`**

After `installMenuBar()` (around line 28) and before the `configManager.onSwap = ...` block, add:

```swift
        launchAtLogin.onStateChange = { [weak self] state in
            self?.menuBar.setLaunchAtLogin(state: state)
        }
        menuBar.setLaunchAtLogin(state: launchAtLogin.state)
```

So the relevant section of `applicationDidFinishLaunching` reads:

```swift
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
```

- [ ] **Step 4: Build, run unit tests, and install**

```bash
swift build
swift test
make install
```

Expected: build + tests pass, app appears in `/Applications/FooTinderPad.app` and launches.

- [ ] **Step 5: Manual smoke test (block 1 — basic toggle)**

Open the menu-bar icon. The new "Launch at Login" item should appear between `Config & Logs ▶` and `Quit`, unchecked, with no warning triangle.

Click it. The macOS notification "Login Item Added" may appear (system-level, not from our app). Re-open the menu — item shows ☑.

Reboot or log out + log back in. After login, the FooTinderPad icon should be in the menu bar without anyone launching it.

If the OS instead returned `.requiresApproval` (typical on a fresh install if the user hasn't approved login items for this signature before), the item should appear as ☐ with a yellow triangle and the tooltip "Approve in System Settings → General → Login Items". Clicking the item should open System Settings → General → Login Items so the user can flip the OS-side switch on.

- [ ] **Step 6: Manual smoke test (block 2 — external sync)**

Open System Settings → General → Login Items, find FooTinderPad, toggle it OFF.

Click our menu icon. The item should now show ☐ (synced via `menuWillOpen` → `refresh()`).

Click it again from our menu. The item should go back to ☑.

- [ ] **Step 7: Commit**

```bash
git add Sources/FooTinderPad/AppDelegate.swift
git commit -m "feat: wire LaunchAtLogin into AppDelegate and menu bar"
```

---

### Task 5: Document the feature in README

**Files:**
- Modify: `README.md`

A short subsection so users know the option exists and where macOS surfaces it.

- [ ] **Step 1: Insert a "Launch at Login" subsection after "Install"**

In `README.md`, find the existing `## Install` section (around line 82). Immediately after the closing of that section (after the `make clean && make install` code block, before `## 支援的控制器按鈕`), insert:

```markdown
## Launch at Login

從選單列點 FooTinderPad 圖示 → `Launch at Login` 切換開關。打開後 macOS 會在使用者登入時自動啟動 app, 同樣的開關也會出現在「系統設定 → 一般 → 登入項目」。

第一次開啟時 macOS 可能要求核可: 選單上的項目會旁邊出現黃色三角警示, 點下去會帶你到「系統設定 → 一般 → 登入項目」, 在那邊把 FooTinderPad 切到開即可。
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document Launch at Login menu option"
```

---

## Definition of Done

- `swift test --filter LaunchAtLoginTests` — 4 tests pass.
- `swift test` — all existing tests still pass (Tasks 3–4 are additive; no behavior changes elsewhere).
- `swift build` — clean build.
- `make install` succeeds; app launches.
- Manual smoke test blocks 1 and 2 in Task 4 both pass on the developer's machine.
- README has the new subsection.
- Five commits land on the branch (one per task).
