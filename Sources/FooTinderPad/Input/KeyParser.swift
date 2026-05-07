import Foundation
import Carbon.HIToolbox
import CoreGraphics

struct ParsedKey: Equatable {
    let mainKey: CGKeyCode?         // nil for modifier-only bindings
    let modifiers: [ModifierKey]    // order matches input string, deduplicated
}

enum KeyParseError: Error, CustomStringConvertible {
    case empty
    case unknownToken(String)
    case nonModifierBeforeFinal(String)
    case emptySeparatorComponent
    case modifierInMainKeyPosition(String)

    var description: String {
        switch self {
        case .empty: return "empty key string"
        case .unknownToken(let t): return "unknown token: \(t)"
        case .nonModifierBeforeFinal(let t): return "non-modifier '\(t)' appeared before final position"
        case .emptySeparatorComponent: return "empty component in key string (check for leading, doubled, or trailing '+')"
        case .modifierInMainKeyPosition(let t): return "modifier '\(t)' cannot appear as the final key"
        }
    }
}

enum KeyParser {

    static func parse(_ raw: String) throws -> ParsedKey {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw KeyParseError.empty }

        let tokens = trimmed.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !tokens.contains(where: { $0.isEmpty }) else { throw KeyParseError.emptySeparatorComponent }

        // Single token: either a main key, or a modifier-only binding
        if tokens.count == 1 {
            let t = tokens[0].lowercased()
            if let mod = modifier(from: t) {
                return ParsedKey(mainKey: nil, modifiers: [mod])
            }
            if let code = mainKey(from: t) {
                return ParsedKey(mainKey: code, modifiers: [])
            }
            throw KeyParseError.unknownToken(tokens[0])
        }

        // Multiple tokens: all-but-last must be modifiers, last is main key
        var mods: [ModifierKey] = []
        for t in tokens.dropLast() {
            let lower = t.lowercased()
            guard let mod = modifier(from: lower) else {
                if mainKey(from: lower) != nil {
                    throw KeyParseError.nonModifierBeforeFinal(t)
                }
                throw KeyParseError.unknownToken(t)
            }
            if !mods.contains(mod) { mods.append(mod) }
        }
        let lastLower = tokens.last!.lowercased()
        guard let main = mainKey(from: lastLower) else {
            if modifier(from: lastLower) != nil {
                throw KeyParseError.modifierInMainKeyPosition(tokens.last!)
            }
            throw KeyParseError.unknownToken(tokens.last!)
        }
        return ParsedKey(mainKey: main, modifiers: mods)
    }

    private static func modifier(from token: String) -> ModifierKey? {
        switch token {
        case "ctrl", "control":         return .leftCtrl
        case "leftctrl", "leftcontrol": return .leftCtrl
        case "rightctrl", "rightcontrol": return .rightCtrl
        case "alt", "option":           return .leftAlt
        case "leftalt", "leftoption":   return .leftAlt
        case "rightalt", "rightoption": return .rightAlt
        case "shift":                   return .leftShift
        case "leftshift":               return .leftShift
        case "rightshift":              return .rightShift
        case "win", "cmd", "command":   return .leftCmd
        case "leftwin", "leftcmd", "leftcommand":   return .leftCmd
        case "rightwin", "rightcmd", "rightcommand": return .rightCmd
        case "fn":                      return .fn
        default: return nil
        }
    }

    private static func mainKey(from token: String) -> CGKeyCode? {
        // Single letters and digits
        if token.count == 1, let scalar = token.unicodeScalars.first {
            if scalar.value >= 0x61 && scalar.value <= 0x7A { return letterKeyCode(scalar) }
            if scalar.value >= 0x30 && scalar.value <= 0x39 { return digitKeyCode(scalar) }
        }
        // Function keys F1..F20
        if token.hasPrefix("f"), let n = Int(token.dropFirst()), (1...20).contains(n) {
            return functionKeyCode(n)
        }
        switch token {
        case "up":          return CGKeyCode(kVK_UpArrow)
        case "down":        return CGKeyCode(kVK_DownArrow)
        case "left":        return CGKeyCode(kVK_LeftArrow)
        case "right":       return CGKeyCode(kVK_RightArrow)
        case "space":       return CGKeyCode(kVK_Space)
        case "return":      return CGKeyCode(kVK_Return)
        case "tab":         return CGKeyCode(kVK_Tab)
        case "escape":      return CGKeyCode(kVK_Escape)
        case "backspace":   return CGKeyCode(kVK_Delete)         // 0x33: macOS "Delete" key (Backspace per PC convention)
        case "delete":      return CGKeyCode(kVK_ForwardDelete)  // 0x75
        case "home":        return CGKeyCode(kVK_Home)
        case "end":         return CGKeyCode(kVK_End)
        case "pageup":      return CGKeyCode(kVK_PageUp)
        case "pagedown":    return CGKeyCode(kVK_PageDown)
        case "minus":       return CGKeyCode(kVK_ANSI_Minus)
        case "equal":       return CGKeyCode(kVK_ANSI_Equal)
        case "leftbracket": return CGKeyCode(kVK_ANSI_LeftBracket)
        case "rightbracket":return CGKeyCode(kVK_ANSI_RightBracket)
        case "backslash":   return CGKeyCode(kVK_ANSI_Backslash)
        case "semicolon":   return CGKeyCode(kVK_ANSI_Semicolon)
        case "quote":       return CGKeyCode(kVK_ANSI_Quote)
        case "comma":       return CGKeyCode(kVK_ANSI_Comma)
        case "period":      return CGKeyCode(kVK_ANSI_Period)
        case "slash":       return CGKeyCode(kVK_ANSI_Slash)
        case "grave":       return CGKeyCode(kVK_ANSI_Grave)
        default: return nil
        }
    }

    private static func letterKeyCode(_ s: Unicode.Scalar) -> CGKeyCode {
        switch s {
        case "a": return CGKeyCode(kVK_ANSI_A); case "b": return CGKeyCode(kVK_ANSI_B)
        case "c": return CGKeyCode(kVK_ANSI_C); case "d": return CGKeyCode(kVK_ANSI_D)
        case "e": return CGKeyCode(kVK_ANSI_E); case "f": return CGKeyCode(kVK_ANSI_F)
        case "g": return CGKeyCode(kVK_ANSI_G); case "h": return CGKeyCode(kVK_ANSI_H)
        case "i": return CGKeyCode(kVK_ANSI_I); case "j": return CGKeyCode(kVK_ANSI_J)
        case "k": return CGKeyCode(kVK_ANSI_K); case "l": return CGKeyCode(kVK_ANSI_L)
        case "m": return CGKeyCode(kVK_ANSI_M); case "n": return CGKeyCode(kVK_ANSI_N)
        case "o": return CGKeyCode(kVK_ANSI_O); case "p": return CGKeyCode(kVK_ANSI_P)
        case "q": return CGKeyCode(kVK_ANSI_Q); case "r": return CGKeyCode(kVK_ANSI_R)
        case "s": return CGKeyCode(kVK_ANSI_S); case "t": return CGKeyCode(kVK_ANSI_T)
        case "u": return CGKeyCode(kVK_ANSI_U); case "v": return CGKeyCode(kVK_ANSI_V)
        case "w": return CGKeyCode(kVK_ANSI_W); case "x": return CGKeyCode(kVK_ANSI_X)
        case "y": return CGKeyCode(kVK_ANSI_Y); case "z": return CGKeyCode(kVK_ANSI_Z)
        default: fatalError("letterKeyCode called with non-letter: \(s)")
        }
    }

    private static func digitKeyCode(_ s: Unicode.Scalar) -> CGKeyCode {
        switch s {
        case "0": return CGKeyCode(kVK_ANSI_0); case "1": return CGKeyCode(kVK_ANSI_1)
        case "2": return CGKeyCode(kVK_ANSI_2); case "3": return CGKeyCode(kVK_ANSI_3)
        case "4": return CGKeyCode(kVK_ANSI_4); case "5": return CGKeyCode(kVK_ANSI_5)
        case "6": return CGKeyCode(kVK_ANSI_6); case "7": return CGKeyCode(kVK_ANSI_7)
        case "8": return CGKeyCode(kVK_ANSI_8); case "9": return CGKeyCode(kVK_ANSI_9)
        default: fatalError("digitKeyCode called with non-digit: \(s)")
        }
    }

    private static func functionKeyCode(_ n: Int) -> CGKeyCode? {
        switch n {
        case 1:  return CGKeyCode(kVK_F1);  case 2:  return CGKeyCode(kVK_F2)
        case 3:  return CGKeyCode(kVK_F3);  case 4:  return CGKeyCode(kVK_F4)
        case 5:  return CGKeyCode(kVK_F5);  case 6:  return CGKeyCode(kVK_F6)
        case 7:  return CGKeyCode(kVK_F7);  case 8:  return CGKeyCode(kVK_F8)
        case 9:  return CGKeyCode(kVK_F9);  case 10: return CGKeyCode(kVK_F10)
        case 11: return CGKeyCode(kVK_F11); case 12: return CGKeyCode(kVK_F12)
        case 13: return CGKeyCode(kVK_F13); case 14: return CGKeyCode(kVK_F14)
        case 15: return CGKeyCode(kVK_F15); case 16: return CGKeyCode(kVK_F16)
        case 17: return CGKeyCode(kVK_F17); case 18: return CGKeyCode(kVK_F18)
        case 19: return CGKeyCode(kVK_F19); case 20: return CGKeyCode(kVK_F20)
        default: return nil
        }
    }
}
