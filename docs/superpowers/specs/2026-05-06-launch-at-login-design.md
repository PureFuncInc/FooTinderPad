# Launch at Login — Design

## Goal

Let the user opt the app into starting automatically when they log into macOS, toggleable from the menu bar. Today the app only starts when launched manually (Finder, `make install`, or Spotlight).

## Scope

- **In scope**: a checkable "Launch at Login" item in the existing menu-bar menu; backed by `SMAppService.mainApp`; warning indication when the OS reports a state that needs the user's attention.
- **Out of scope**: a launch-at-login flag in `config.json` (registration is OS-level, not app-level — the JSON would be a second source of truth that can lie); a separate Preferences window; deep automation of the macOS approval flow.

## User-facing model

A new top-level menu item between `Config & Logs` and `Quit`, in its own separator-bounded group:

```
About FooTinderPad
─────
DualSense Wireless Controller   (status line)
─────
Config & Logs                ▶
─────
☑ Launch at Login                ← new
─────
Quit                          ⌘Q
```

**Defaults**: off. The app does not auto-register on first run; the user opts in.

**Click behavior depends on current state**:

| State | Visual | Click |
|---|---|---|
| `.disabled` | ☐, no image | call `SMAppService.mainApp.register()` |
| `.enabled` | ☑, no image | call `SMAppService.mainApp.unregister()` |
| `.requiresApproval` | ☐ + 🔺 (yellow `exclamationmark.triangle.fill`), tooltip: "Approve in System Settings → General → Login Items" | call `SMAppService.openSystemSettingsLoginItems()` (re-trying `register()` is a no-op until the user approves) |
| `.failed(error)` | ☐ + 🔺, tooltip shows `error.localizedDescription` | call `SMAppService.openSystemSettingsLoginItems()` (failures are typically signing/permission issues better resolved in System Settings) |

The menu item is refreshed on `NSMenuDelegate.menuWillOpen`, so toggles made in System Settings show up the next time the user opens the menu — no polling timer.

## Architecture

A new `LaunchAtLogin` class (Sources/FooTinderPad/System/), modeled after `AccessibilityGate`: owns its own state, exposes an `onStateChange` callback, has no UI dependencies. AppDelegate wires it to `MenuBar`.

```swift
enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case failed(String)   // error.localizedDescription — String for Equatable + logging
}

final class LaunchAtLogin {
    private(set) var state: LaunchAtLoginState
    var onStateChange: ((LaunchAtLoginState) -> Void)?

    init() { ... refresh once ... }
    func refresh()                         // re-read SMAppService.mainApp.status
    func handleClick()                     // state-aware dispatch (see table above)
}
```

`handleClick()` dispatches via a pure helper that's the only piece worth unit-testing:

```swift
enum LaunchAtLoginAction { case enable, disable, openSystemSettings }

extension LaunchAtLogin {
    static func action(for state: LaunchAtLoginState) -> LaunchAtLoginAction {
        switch state {
        case .disabled:                      return .enable
        case .enabled:                       return .disable
        case .requiresApproval, .failed:     return .openSystemSettings
        }
    }
}
```

### Flow

```
App launch
  → AppDelegate inits LaunchAtLogin (constructor runs refresh())
  → MenuBar.install adds the "Launch at Login" item, reflecting the initial state

User opens the menu
  → NSMenuDelegate.menuWillOpen fires
  → AppDelegate calls launchAtLogin.refresh()
  → if status changed (e.g. user disabled in System Settings), onStateChange fires
  → MenuBar updates check + image

User clicks "Launch at Login"
  → MenuBar → onToggleLaunchAtLogin
  → AppDelegate → launchAtLogin.handleClick()
       → action(for: state):
         .enable             → try register();   refresh()
         .disable            → try unregister(); refresh()
         .openSystemSettings → SMAppService.openSystemSettingsLoginItems()
       → onStateChange fires if state moved
  → MenuBar updates
```

### State mapping from `SMAppService.Status`

```swift
switch SMAppService.mainApp.status {
case .enabled:           return .enabled
case .notRegistered:     return .disabled
case .requiresApproval:  return .requiresApproval
case .notFound:          return .failed("login item not found")  // very rare; bundle/signing
@unknown default:        return .failed("unknown SMAppService status")
}
```

`register()` / `unregister()` throws → `state = .failed(error.localizedDescription)`, log via `os.Logger`.

### Why a wrapper instead of calling `SMAppService` directly from AppDelegate

- Mirrors the existing pattern with `AccessibilityGate` (system-permission state object with `onStateChange`). AppDelegate stays as wiring code, not logic.
- Centralizes the `try/catch` and the four-way state mapping.
- Makes the pure dispatch logic testable in isolation without touching `SMAppService` itself.

## New / modified files

| File | Change |
|---|---|
| `Sources/FooTinderPad/System/LaunchAtLogin.swift` | **NEW** — the wrapper described above (~80 lines). |
| `Sources/FooTinderPad/UI/MenuBar.swift` | Conform to `NSMenuDelegate` (today it's a plain class); set `menu.delegate = self` in `install()`; implement `menuWillOpen(_:)` → call `onMenuWillOpen?()`. Add the menu item; new callbacks `onToggleLaunchAtLogin: (() -> Void)?` and `onMenuWillOpen: (() -> Void)?`; method to update the item's check + warning image + tooltip given a `LaunchAtLoginState`. |
| `Sources/FooTinderPad/AppDelegate.swift` | Instantiate `LaunchAtLogin`; wire callbacks; call `refresh()` on `menuWillOpen`. |
| `Tests/FooTinderPadTests/LaunchAtLoginTests.swift` | **NEW** — table-driven test of `LaunchAtLogin.action(for:)` covering all four states. |
| `README.md` | One-line note under "Install" or a new "Launch at Login" subsection: how to enable, where macOS surfaces it (System Settings → General → Login Items). |

`Info.plist`, `Makefile`, `Package.swift` — unchanged. `SMAppService.mainApp` works on any signed `.app`; no entitlements needed for the main-app variant.

## Edge cases

1. **First-time `register()` on a fresh install** — macOS may return `.requiresApproval` and surface a system notification asking the user to approve. The menu reflects this with the yellow triangle; clicking sends them to the right Settings pane.
2. **User disables in System Settings** — next `menuWillOpen` triggers `refresh()`, menu syncs to ☐. No polling needed.
3. **App reinstall via `make install`** — same bundle id + same signing cert (`FooTinderPadDev`) → LaunchServices treats it as the same app, registration carries over. Ad-hoc-signed builds may break this; user falls back to clicking again.
4. **App moved between locations** — `SMAppService` tracks the registration by bundle id; LaunchServices auto-resolves the new path. No special handling.
5. **Click on `.requiresApproval` opens System Settings, NOT a re-`register()`** — re-registering before the user approves is a no-op and would leave them stuck. Sending them to Settings is the only path forward.
6. **`@unknown default` from `SMAppService.Status`** — fall through to `.failed("unknown SMAppService status")` so future macOS values surface as warnings rather than silently misbehaving.
7. **`unregister()` while already `.notRegistered`** — `SMAppService` tolerates this; we still call `refresh()` afterwards to confirm.

## Tests

`LaunchAtLoginTests` (new), table-driven, ~20 lines total:

- `testActionWhenDisabled` — `.disabled` → `.enable`
- `testActionWhenEnabled` — `.enabled` → `.disable`
- `testActionWhenRequiresApproval` — `.requiresApproval` → `.openSystemSettings`
- `testActionWhenFailed` — `.failed("...")` → `.openSystemSettings`

Not unit-tested (matches `AccessibilityGate`'s pragmatic stance):

- `SMAppService.mainApp.register()` / `.unregister()` / `openSystemSettingsLoginItems()` — system API wrappers, mocking would require a protocol layer that buys nothing; running them would also pollute the developer's LaunchServices registration database.
- `SMAppService.Status` → `LaunchAtLoginState` mapping — trivial 1:1 switch; covered implicitly by the manual smoke test below.

### Manual smoke test (acceptance checklist)

1. `make install`. Open the menu — "Launch at Login" appears unchecked, no triangle.
2. Click it → ☑. **Reboot.** App auto-launches into the menu bar.
3. Open System Settings → General → Login Items. Toggle FooTinderPad off.
4. Re-open our menu — item now shows ☐ (synced via `menuWillOpen`).
5. Click it again → ☑ (re-registers cleanly).
6. (Best-effort) On a fresh install where macOS returns `.requiresApproval`, verify the yellow triangle appears, hovering shows the tooltip, and clicking opens System Settings → Login Items.

## Out of scope (future)

- Click-to-open-Settings affordance for the `.failed` state beyond what we already do (e.g., showing the full error in a popover).
- A first-run prompt asking whether to enable launch-at-login.
- Surfacing launch-at-login state in the main status line (rejected during brainstorming — keeps the bar quiet).
