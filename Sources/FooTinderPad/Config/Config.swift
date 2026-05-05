import Foundation
import CoreGraphics

// MARK: - Resolved (runtime) model

/// A map from every ControllerButton to its resolved binding.
/// The subscript always returns a non-optional ResolvedBinding (.none when unset),
/// and `count` always equals ControllerButton.allCases.count.
struct BindingMap: Equatable {
    private var storage: [ControllerButton: ResolvedBinding]

    init(_ storage: [ControllerButton: ResolvedBinding] = [:]) {
        self.storage = storage
    }

    subscript(button: ControllerButton) -> ResolvedBinding {
        get { storage[button] ?? ResolvedBinding.none }
        set { storage[button] = newValue }
    }

    var count: Int { ControllerButton.allCases.count }
}

struct ResolvedConfig: Equatable {
    let deadzone: Double
    let mouseSpeed: Double
    let scrollSpeed: Double
    let leftStick: StickRole
    let rightStick: StickRole
    let bindings: BindingMap
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

        // Bindings — BindingMap returns .none for missing keys
        var resolved = BindingMap()

        for (rawKey, rawBinding) in (raw.bindings ?? [:]) {
            guard let button = ControllerButton(rawValue: rawKey) else {
                warnings.append("unknown button '\(rawKey)' — entry dropped")
                continue
            }
            switch rawBinding.type {
            case "none":
                break // leave as default .none
            case "mouseButton":
                if let m = rawBinding.button {
                    resolved[button] = .mouseButton(m)
                } else {
                    warnings.append("\(rawKey): mouseButton missing 'button' field — set to none")
                }
            case "key":
                guard let keyStr = rawBinding.key else {
                    warnings.append("\(rawKey): key missing 'key' field — set to none")
                    continue
                }
                do {
                    let parsed = try KeyParser.parse(keyStr)
                    resolved[button] = .key(mainKey: parsed.mainKey, modifiers: parsed.modifiers)
                } catch {
                    warnings.append("\(rawKey): could not parse '\(keyStr)' (\(error)) — set to none")
                }
            default:
                warnings.append("\(rawKey): unknown binding type '\(rawBinding.type)' — set to none")
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
