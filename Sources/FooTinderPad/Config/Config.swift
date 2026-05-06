import Foundation
import CoreGraphics

// MARK: - Resolved (runtime) model

struct ResolvedConfig: Equatable {
    let deadzone: Double
    let mouseSpeed: Double
    let scrollSpeed: Double
    let leftStick: StickRole
    let rightStick: StickRole
    let bindings: [ControllerButton: ResolvedBinding]

    /// In-memory placeholder used before the first successful load. Mirrors the
    /// shape produced by ConfigLoader so consumers can rely on the bindings
    /// dictionary always containing every ControllerButton case.
    static let empty = ResolvedConfig(
        deadzone: 0.15,
        mouseSpeed: 15,
        scrollSpeed: 5,
        leftStick: .mouse,
        rightStick: .scroll,
        bindings: Dictionary(uniqueKeysWithValues: ControllerButton.allCases.map { ($0, ResolvedBinding.none) })
    )
}

enum ResolvedBinding: Equatable {
    case key(mainKey: CGKeyCode?, modifiers: [ModifierKey])
    case mouseButton(MouseButton)
    case none
}

// MARK: - Raw (JSON-shaped) model

private struct RawConfig: Decodable {
    var deadzone: Double?
    var mouseSpeed: Double?
    var scrollSpeed: Double?
    var leftStick: StickRole?
    var rightStick: StickRole?
    var bindings: [String: RawBinding]?
}

private struct RawBinding: Decodable {
    let type: String
    let key: String?
    let button: MouseButton?
}

// MARK: - Loader

struct LoadResult {
    let config: ResolvedConfig
    let warnings: [String]
}

enum ConfigLoader {

    static func load(from data: Data) throws -> LoadResult {
        let raw = try JSONDecoder().decode(RawConfig.self, from: data)
        var warnings: [String] = []

        // Numeric scalars
        var deadzone = raw.deadzone ?? 0.15
        if deadzone < 0 || deadzone > 0.49 {
            warnings.append("deadzone \(deadzone) out of range; clamped to [0.0, 0.49]")
            deadzone = max(0.0, min(0.49, deadzone))
        }
        var mouseSpeed = raw.mouseSpeed ?? 15
        if mouseSpeed <= 0 {
            warnings.append("mouseSpeed must be > 0; using default 15")
            mouseSpeed = 15
        }
        var scrollSpeed = raw.scrollSpeed ?? 5
        if scrollSpeed <= 0 {
            warnings.append("scrollSpeed must be > 0; using default 5")
            scrollSpeed = 5
        }

        let leftStick = raw.leftStick ?? .mouse
        let rightStick = raw.rightStick ?? .scroll

        // Bindings — start with all .none, then overlay valid ones
        var resolved: [ControllerButton: ResolvedBinding] = [:]
        for b in ControllerButton.allCases { resolved[b] = ResolvedBinding.none }

        for (rawKey, rawBinding) in (raw.bindings ?? [:]) {
            guard let button = ControllerButton(rawValue: rawKey) else {
                warnings.append("unknown button '\(rawKey)' — entry dropped")
                continue
            }
            switch rawBinding.type {
            case "none":
                resolved[button] = ResolvedBinding.none
            case "mouseButton":
                if let m = rawBinding.button {
                    resolved[button] = .mouseButton(m)
                } else {
                    warnings.append("\(rawKey): mouseButton missing 'button' field — set to none")
                    resolved[button] = ResolvedBinding.none
                }
            case "key":
                guard let keyStr = rawBinding.key else {
                    warnings.append("\(rawKey): key missing 'key' field — set to none")
                    resolved[button] = ResolvedBinding.none
                    continue
                }
                do {
                    let parsed = try KeyParser.parse(keyStr)
                    resolved[button] = .key(mainKey: parsed.mainKey, modifiers: parsed.modifiers)
                } catch {
                    warnings.append("\(rawKey): could not parse '\(keyStr)' (\(error)) — set to none")
                    resolved[button] = ResolvedBinding.none
                }
            default:
                warnings.append("\(rawKey): unknown binding type '\(rawBinding.type)' — set to none")
                resolved[button] = ResolvedBinding.none
            }
        }

        let cfg = ResolvedConfig(
            deadzone: deadzone,
            mouseSpeed: mouseSpeed,
            scrollSpeed: scrollSpeed,
            leftStick: leftStick,
            rightStick: rightStick,
            bindings: resolved
        )
        return LoadResult(config: cfg, warnings: warnings)
    }
}
