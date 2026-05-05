import XCTest
import Carbon.HIToolbox
@testable import FooTinderPad

final class KeyParserTests: XCTestCase {
    func testArrowUp() {
        let r = try? KeyParser.parse("Up")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_UpArrow))
        XCTAssertEqual(r?.modifiers, [])
    }

    func testReturnIsKeyCode0x24() {
        let r = try? KeyParser.parse("Return")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_Return))
        XCTAssertEqual(r?.modifiers, [])
    }

    func testAltReturnCombo() {
        let r = try? KeyParser.parse("Alt+Return")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_Return))
        XCTAssertEqual(r?.modifiers, [.leftAlt])
    }

    func testCtrlShiftDigit() {
        let r = try? KeyParser.parse("Ctrl+Shift+4")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_ANSI_4))
        XCTAssertEqual(r?.modifiers, [.leftCtrl, .leftShift])
    }

    func testLowercaseAndAliases() {
        let r = try? KeyParser.parse("option+return")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_Return))
        XCTAssertEqual(r?.modifiers, [.leftAlt])
    }

    func testWinAliasMapsToCmd() {
        let r = try? KeyParser.parse("Win+Space")
        XCTAssertEqual(r?.mainKey, CGKeyCode(kVK_Space))
        XCTAssertEqual(r?.modifiers, [.leftCmd])
    }

    func testModifierOnlyRightShift() {
        let r = try? KeyParser.parse("RightShift")
        XCTAssertNil(r?.mainKey)
        XCTAssertEqual(r?.modifiers, [.rightShift])
    }

    func testBackspaceIs0x33() {
        let r = try? KeyParser.parse("Backspace")
        XCTAssertEqual(r?.mainKey, 0x33)
    }

    func testDeleteIsForwardDelete0x75() {
        let r = try? KeyParser.parse("Delete")
        XCTAssertEqual(r?.mainKey, 0x75)
    }

    func testEmptyRejected() {
        XCTAssertThrowsError(try KeyParser.parse(""))
    }

    func testUnknownTokenRejected() {
        XCTAssertThrowsError(try KeyParser.parse("Foo"))
    }

    func testTrailingPlusRejected() {
        XCTAssertThrowsError(try KeyParser.parse("Alt+"))
    }

    func testUnknownMainKeyRejected() {
        XCTAssertThrowsError(try KeyParser.parse("Alt+Foo"))
    }

    func testNonModifierBeforeFinalRejected() {
        XCTAssertThrowsError(try KeyParser.parse("A+B"))
    }
}
