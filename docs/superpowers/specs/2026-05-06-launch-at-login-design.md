# Launch at Login — Design

## Revision history

- **r1 (initial)** — `SMAppService.mainApp` only.
- **r2 (current)** — adds a LaunchAgent plist fallback for self-signed builds where `SMAppService` returns `.notFound` (no Team Identifier in the cert). Replaces the yellow-triangle warning with a softer info icon. Replaces the macOS-native checkmark (`NSMenuItem.state = .on`) with a green `checkmark.circle.fill` image so the visual signal is consistent across all states.

## Goal

Let the user opt the app into starting automatically when they log into macOS, toggleable from the menu bar. Today the app only starts when launched manually (Finder, `make install`, or Spotlight).

## Scope

- **In scope**: a "Launch at Login" item in the menu-bar menu; tries `SMAppService.mainApp` first, falls back to writing `~/Library/LaunchAgents/com.purefuncinc.FooTinderPad.plist` when SMAppService can't register (typically because the build is signed with a self-signed cert that has no Team Identifier); soft info-icon indication when the OS reports a state that still needs user attention.
- **Out of scope**: a launch-at-login flag in `config.json` (registration is OS-level, not app-level — JSON would be a second source of truth that can lie); a separate Preferences window; deep automation of the macOS approval flow; calling `launchctl load`/`bootstrap` to start the LaunchAgent immediately (the running app instance already provides the running process — `RunAtLoad` covers the next login).

## User-facing model

A new top-level menu item between `Config & Logs` and `Quit`, in its own separator-bounded group:

```
About FooTinderPad
─────
DualSense Wireless Controller   (status line)
─────
Config & Logs                ▶
─────
✓ Launch at Login                ← new (green checkmark image when enabled, blank when disabled)
─────
Quit                          ⌘Q
```

**Defaults**: off. The app does not auto-register on first run; the user opts in.

**Visual signal is image-only** — we do NOT use `NSMenuItem.state = .on/.off`. All four states render as a left-side SF Symbol image (or no image), keeping the visual rule uniform regardless of which underlying mechanism (SMAppService or LaunchAgent) is in play:

| State | Image | Tooltip |
|---|---|---|
| `.enabled` | green `checkmark.circle.fill` (palette `[.systemGreen]`) | none |
| `.disabled` | no image | none |
| `.requiresApproval` | gray `info.circle` (palette `[.systemGray]`) | "Approve in System Settings → General → Login Items" |
| `.failed(error)` | gray `info.circle` (palette `[.systemGray]`) | `error.localizedDescription` |

**Click behavior depends on current state**:

| State | Click |
|---|---|
| `.disabled` | try `SMAppService.mainApp.register()`; if it throws OR yields `.notFound` after the call, fall back to writing the LaunchAgent plist; refresh state |
| `.enabled` | if our LaunchAgent plist exists, delete it; also call `SMAppService.mainApp.unregister()` (best-effort, ignore errors); refresh state |
| `.requiresApproval` | call `SMAppService.openSystemSettingsLoginItems()` (re-trying `register()` is a no-op until the user approves) |
| `.failed(error)` | call `SMAppService.openSystemSettingsLoginItems()` (failures are typically signing/permission issues better resolved in System Settings) |

The menu item is refreshed on `NSMenuDelegate.menuWillOpen`, so toggles made in System Settings (or the plist being deleted out from under us) show up the next time the user opens the menu — no polling timer.

### Why the fallback is invisible to the user

A user with a Developer ID-signed build hits the SMAppService path and never sees the LaunchAgent. A user with a self-signed build (no Team Identifier) gets `.notFound` from SMAppService; rather than surface that as an error, we silently write the plist and report `.enabled`. The user only knows there was a fallback if they look in `~/Library/LaunchAgents/`. This trades the previous "user can manage from System Settings → Login Items" affordance (LaunchAgent plists do not appear there) for actually-working auto-launch, which is the whole point of the feature.

## Architecture

A `LaunchAtLogin` class (Sources/FooTinderPad/System/), modeled after `AccessibilityGate`: owns its own state, exposes an `onStateChange` callback, has no UI dependencies. AppDelegate wires it to `MenuBar`.

```swift
enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    case requiresApproval
    case failed(String)   // error.localizedDescription — String for Equatable + logging
}

final class LaunchAtLogin {
    private let plistURL: URL
    private(set) var state: LaunchAtLoginState
    var onStateChange: ((LaunchAtLoginState) -> Void)?

    init(plistURL: URL = LaunchAtLogin.defaultPlistURL) { ... reads state once ... }
    func refresh()                         // re-read state (plist-first, then SMAppService)
    func handleClick()                     // state-aware dispatch with fallback (see tables above)
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
  → if state changed (e.g. user disabled in System Settings, plist deleted externally),
    onStateChange fires
  → MenuBar updates image + tooltip

User clicks "Launch at Login"
  → MenuBar → onToggleLaunchAtLogin
  → AppDelegate → launchAtLogin.handleClick()
       → action(for: state):
         .enable             → try register(); if throws OR resulting status == .notFound,
                                fall back to writing plist; refresh()
         .disable            → if plist exists, remove it; try unregister() (best-effort); refresh()
         .openSystemSettings → SMAppService.openSystemSettingsLoginItems()
       → onStateChange fires if state moved
  → MenuBar updates
```

### State mapping (`readState()`)

The plist takes precedence. If our plist is at `~/Library/LaunchAgents/com.purefuncinc.FooTinderPad.plist`, the LaunchAgent path is in effect — that wins regardless of what SMAppService says. Otherwise we read SMAppService:

```swift
private static let plistURL: URL =
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.purefuncinc.FooTinderPad.plist")

private static func readState() -> LaunchAtLoginState {
    if FileManager.default.fileExists(atPath: plistURL.path) {
        return .enabled
    }
    switch SMAppService.mainApp.status {
    case .enabled:           return .enabled
    case .notRegistered:     return .disabled
    case .notFound:          return .disabled                    // self-signed: looks "off, can enable"
    case .requiresApproval:  return .requiresApproval
    @unknown default:        return .failed("unknown SMAppService status")
    }
}
```

Note: `.notFound` is now mapped to `.disabled` (was `.failed("login item not found")` in r1). The fallback handles the actual mechanism choice on click; the user never sees `.notFound` as a failure.

### Click handler — fallback enable

```swift
case .enable:
    var smaSucceeded = false
    do {
        try SMAppService.mainApp.register()
        // re-read status: if Apple accepted us, it'll be .enabled or .requiresApproval
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            smaSucceeded = true
        default:
            smaSucceeded = false
        }
    } catch {
        log.info("SMAppService.register failed (\(error.localizedDescription)); falling back to LaunchAgent plist")
        smaSucceeded = false
    }
    if !smaSucceeded {
        do {
            try Self.writePlist()
        } catch {
            log.error("plist write failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            onStateChange?(state)
            return
        }
    }
    refresh()
```

### Click handler — disable

```swift
case .disable:
    if FileManager.default.fileExists(atPath: Self.plistURL.path) {
        do {
            try FileManager.default.removeItem(at: Self.plistURL)
        } catch {
            log.error("plist remove failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            onStateChange?(state)
            return
        }
    }
    try? SMAppService.mainApp.unregister()  // best-effort, ignore failures
    refresh()
```

### Plist contents (`writePlist()`)

```swift
private static func writePlist() throws {
    let dir = plistURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let exec = Bundle.main.executableURL?.path else {
        throw LaunchAtLoginError.noExecutablePath
    }
    let content: [String: Any] = [
        "Label": "com.purefuncinc.FooTinderPad",
        "ProgramArguments": [exec],
        "RunAtLoad": true,
        "KeepAlive": false,
    ]
    let data = try PropertyListSerialization.data(
        fromPropertyList: content, format: .xml, options: 0)
    try data.write(to: plistURL, options: .atomic)
}
```

`KeepAlive: false` makes this a one-shot at-login launch — if the user quits the app, launchd does not respawn it. That matches the macOS Login-Item convention and the user's mental model of an opt-in auto-start.

We deliberately do NOT call `launchctl bootstrap`/`load`. The plist's `RunAtLoad` only fires at the start of a user login session, which is exactly when we want it. Loading it now would launch a second instance immediately, since the user's current login session is already underway.

### Why a wrapper instead of calling `SMAppService` directly from AppDelegate

- Mirrors the existing pattern with `AccessibilityGate` (system-permission state object with `onStateChange`). AppDelegate stays as wiring code, not logic.
- Centralizes the `try/catch`, the state mapping, and (now) the SMAppService-then-LaunchAgent fallback decision in one place.
- Makes the pure dispatch logic AND the plist-aware state read testable in isolation, without touching `SMAppService` or the user's real `~/Library/LaunchAgents`.

## New / modified files

| File | Change |
|---|---|
| `Sources/FooTinderPad/System/LaunchAtLogin.swift` | The wrapper described above. Adds: `plistURL` static, `writePlist()`, `readState()` plist-first priority, fallback logic in `handleClick()`. Existing pure helper `action(for:)` is unchanged. |
| `Sources/FooTinderPad/UI/MenuBar.swift` | Update `setLaunchAtLogin(state:)` to image-only rendering (drop `NSMenuItem.state` usage). Add `enabledImage()` (green `checkmark.circle.fill`). Replace yellow-triangle `warningImage()` with gray `info.circle` (rename to `infoImage()` for accuracy). Other Task-3 changes (NSMenuDelegate conformance, menu item insertion, callbacks) stay as-is. |
| `Sources/FooTinderPad/AppDelegate.swift` | No further changes — wiring from r1 still applies. |
| `Tests/FooTinderPadTests/LaunchAtLoginTests.swift` | Existing 4 tests for `action(for:)` are preserved (the routing rule is unchanged). New tests for `writePlist()` content shape and `readState()` plist-first priority — using a custom `plistURL` injection or temp directory to avoid touching the real `~/Library/LaunchAgents`. |
| `README.md` | Existing Launch at Login subsection stays; add a paragraph noting that on builds without a Developer ID Team Identifier, the feature falls back to `~/Library/LaunchAgents/com.purefuncinc.FooTinderPad.plist`. The toggle in our menu is the source of truth in that case (the OS Login Items pane will not list LaunchAgent-based entries). |

`Info.plist`, `Makefile`, `Package.swift` — still unchanged. `SMAppService.mainApp` works on any signed `.app`; no entitlements needed.

### Testability of `writePlist()` and `readState()`

To unit-test without touching `~/Library/LaunchAgents`, expose the plist URL via an internal `init(plistURL:)` overload (default arg falls back to the production path). Tests pass a temp-directory URL. `readState()` and `writePlist()` use the instance's `plistURL` (not a static) when the testable override is present — keep the static as a default-builder for the production path. Production code paths are unchanged.

```swift
final class LaunchAtLogin {
    private let plistURL: URL
    init(plistURL: URL = LaunchAtLogin.defaultPlistURL) {
        self.plistURL = plistURL
        self.state = Self.readState(plistURL: plistURL)
    }
    static let defaultPlistURL: URL = ...
}
```

## Edge cases

1. **First-time `register()` on a Developer-ID-signed install** — macOS may return `.requiresApproval`. The menu shows the gray info icon; clicking sends them to System Settings → Login Items.
2. **First-time enable on a self-signed install** — `register()` does not throw but the resulting status is `.notFound` (no Team Identifier in the cert means LaunchServices cannot persist the registration). We detect this and fall back to writing the plist; the user sees the green check.
3. **User disables in System Settings (SMAppService path)** — next `menuWillOpen` triggers `refresh()`, menu syncs to no-image. No polling needed.
4. **User deletes the plist manually** — next `menuWillOpen` re-reads `readState()`; absent plist + `.notRegistered`/`.notFound` from SMAppService → `.disabled`, menu syncs.
5. **App reinstall via `make install`** — plist's `ProgramArguments` points to `/Applications/FooTinderPad.app/Contents/MacOS/FooTinderPad`, which is replaced by `make install` but the path is unchanged, so the plist still works.
6. **App moved between locations** — only the SMAppService path is location-resilient (LaunchServices tracks by bundle id). The plist hardcodes the path captured by `Bundle.main.executableURL` at write time; if the app moves, the plist becomes stale and launchd will fail to launch at login. Acceptable for now — moving the app is an explicit user action and they can re-toggle.
7. **Click on `.requiresApproval` opens System Settings, NOT a re-`register()`** — re-registering before the user approves is a no-op and would leave them stuck. The fallback is also NOT triggered for `.requiresApproval` — that's a "user must approve" state, not a "SMAppService failed" state.
8. **Both plist AND SMAppService active simultaneously** — possible if a Developer-ID build was previously enabled (SMAppService active) and later resigned with a self-signed cert (plist gets written on next enable). Both will fire at login (one extra instance briefly, but app should single-instance via bundle id). Disable removes the plist AND calls `unregister()` to clean both.
9. **`@unknown default` from `SMAppService.Status`** — fall through to `.failed("unknown SMAppService status")` so future macOS values surface as a soft warning rather than silently misbehaving.
10. **`unregister()` while already `.notRegistered`** — `SMAppService` tolerates this; the `try?` makes any error silent.
11. **`writePlist()` IO error** (full disk, sandbox restriction, permission denied) — caught, mapped to `.failed(error.localizedDescription)`, surfaced via the menu's gray info icon and tooltip.

## Tests

`LaunchAtLoginTests` (existing 4 + new):

**Pure helper (unchanged from r1)**

- `testActionWhenDisabled` — `.disabled` → `.enable`
- `testActionWhenEnabled` — `.enabled` → `.disable`
- `testActionWhenRequiresApproval` — `.requiresApproval` → `.openSystemSettings`
- `testActionWhenFailed` — `.failed("...")` → `.openSystemSettings`

**Plist filesystem behavior (new)** — uses temp directory injected via `init(plistURL:)`:

- `testReadStateWhenPlistExistsReturnsEnabled` — write a sentinel file at the temp `plistURL`, init `LaunchAtLogin`, expect `state == .enabled` (regardless of what SMAppService reports).
- `testReadStateWhenPlistAbsentDelegatesToSMAppService` — temp `plistURL` doesn't exist, init runs, `state` matches SMAppService status mapping.
- `testWritePlistEmitsExpectedKeys` — call a static `writePlist(at:executablePath:)` (extracted from `writePlist()` for testability), parse the output with `PropertyListSerialization`, assert keys: `Label == "com.purefuncinc.FooTinderPad"`, `RunAtLoad == true`, `KeepAlive == false`, `ProgramArguments == [executablePath]`.
- `testRemovePlistIsIdempotentWhenAbsent` — call the disable path with no plist present; expect no throw and state stays `.disabled`. (Specifically: deleting a non-existent file should be a no-op rather than throwing.)

Not unit-tested (matches `AccessibilityGate`'s pragmatic stance):

- `SMAppService.mainApp.register()` / `.unregister()` / `openSystemSettingsLoginItems()` — system API wrappers; mocking would require a protocol layer that buys nothing; running them would pollute the developer's LaunchServices registration database.

### Manual smoke test (acceptance checklist)

1. `make install`. Open the menu — "Launch at Login" appears with no image, no info icon (state = `.disabled`).
2. Click it → green checkmark appears. Verify which path was taken:
   - Run `ls ~/Library/LaunchAgents/com.purefuncinc.FooTinderPad.plist` — if present, fallback path is in effect (self-signed build).
   - Otherwise, check System Settings → General → Login Items — FooTinderPad should appear there enabled (Developer-ID build).
3. **Reboot.** App auto-launches into the menu bar regardless of which mechanism is in effect.
4. Open the menu, click "Launch at Login" again → green check disappears. Verify the plist file is gone (`ls` returns no such file) AND System Settings entry is off/absent.
5. (Developer-ID build only) Repeat steps 2–3, then disable from System Settings instead of from our menu. Re-open our menu — green check syncs off (via `menuWillOpen → refresh()`).
6. (Best-effort) On a fresh Developer-ID install where macOS returns `.requiresApproval`, verify the gray `info.circle` appears, hovering shows the "Approve in System Settings" tooltip, and clicking opens System Settings → Login Items.

## Out of scope (future)

- Click-to-open-Settings affordance for the `.failed` state beyond what we already do (e.g., showing the full error in a popover).
- A first-run prompt asking whether to enable launch-at-login.
- Surfacing launch-at-login state in the main status line (rejected during brainstorming — keeps the bar quiet).
- Following the binary across Finder-initiated app moves (the LaunchAgent plist hardcodes the path; if the app is moved, the user re-toggles).
- Calling `launchctl bootstrap`/`load` to start the LaunchAgent immediately (would launch a duplicate instance during the active session — `RunAtLoad` covers the next login, which is what we want).
- Migration of users who enabled the feature under r1's mapping (`.notFound → .failed`). Practically there's no migration: `.notFound` users couldn't successfully enable, so there's no persisted enabled state to migrate. The first click after the upgrade naturally enters the new fallback path.
