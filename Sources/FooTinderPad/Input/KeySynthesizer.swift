import Foundation
import Carbon.HIToolbox
import CoreGraphics
import os

final class KeySynthesizer {
    private let sink: EventSink
    private var modCount: [ModifierKey: Int] = [:]
    private var heldMainKeys: Set<CGKeyCode> = []
    private let log = Logger(subsystem: "com.purefuncinc.FooTinderPad", category: "KeySynthesizer")

    init(sink: EventSink) {
        self.sink = sink
    }

    func press(_ k: ParsedKey) {
        for m in k.modifiers { acquire(m) }
        if let main = k.mainKey {
            sink.keyEvent(keyCode: main, down: true, flags: currentFlags())
            heldMainKeys.insert(main)
        }
    }

    func release(_ k: ParsedKey) {
        if let main = k.mainKey, heldMainKeys.contains(main) {
            sink.keyEvent(keyCode: main, down: false, flags: currentFlags())
            heldMainKeys.remove(main)
        }
        for m in k.modifiers.reversed() { releaseMod(m) }
    }

    /// Releases every held key + modifier. Used on config swap and controller switch.
    func drain() {
        for key in heldMainKeys {
            sink.keyEvent(keyCode: key, down: false, flags: currentFlags())
        }
        heldMainKeys.removeAll()
        let snapshot = modCount
        for (mod, count) in snapshot where count > 0 {
            for _ in 0..<count { releaseMod(mod) }
        }
    }

    // MARK: - private

    private func acquire(_ m: ModifierKey) {
        let prev = modCount[m] ?? 0
        modCount[m] = prev + 1
        if prev == 0, let kc = keyCode(for: m) {
            sink.keyEvent(keyCode: kc, down: true, flags: currentFlags())
        }
    }

    private func releaseMod(_ m: ModifierKey) {
        let prev = modCount[m] ?? 0
        guard prev > 0 else {
            log.warning("releaseMod underflow on \(String(describing: m), privacy: .public)")
            return
        }
        modCount[m] = prev - 1
        if prev == 1, let kc = keyCode(for: m) {
            // currentFlags() now excludes this modifier because count just dropped to 0
            sink.keyEvent(keyCode: kc, down: false, flags: currentFlags())
        }
    }

    private func currentFlags() -> CGEventFlags {
        var f: CGEventFlags = []
        for (m, c) in modCount where c > 0 {
            switch m {
            case .leftCtrl, .rightCtrl:   f.insert(.maskControl)
            case .leftAlt,  .rightAlt:    f.insert(.maskAlternate)
            case .leftShift,.rightShift:  f.insert(.maskShift)
            case .leftCmd,  .rightCmd:    f.insert(.maskCommand)
            case .fn:                     f.insert(.maskSecondaryFn)
            }
        }
        return f
    }

    private func keyCode(for m: ModifierKey) -> CGKeyCode? {
        switch m {
        case .leftCtrl:   return CGKeyCode(kVK_Control)
        case .rightCtrl:  return CGKeyCode(kVK_RightControl)
        case .leftAlt:    return CGKeyCode(kVK_Option)
        case .rightAlt:   return CGKeyCode(kVK_RightOption)
        case .leftShift:  return CGKeyCode(kVK_Shift)
        case .rightShift: return CGKeyCode(kVK_RightShift)
        case .leftCmd:    return CGKeyCode(kVK_Command)
        case .rightCmd:   return CGKeyCode(kVK_RightCommand)
        case .fn:         return nil
        }
    }
}
