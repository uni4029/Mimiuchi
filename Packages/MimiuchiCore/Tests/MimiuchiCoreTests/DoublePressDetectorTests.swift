import AppKit
import Carbon.HIToolbox
import XCTest

@testable import MimiuchiCore

final class DoublePressDetectorTests: XCTestCase {
    private let c = UInt16(kVK_ANSI_C)
    private let v = UInt16(kVK_ANSI_V)

    private func detector(interval: TimeInterval = 0.45) -> DoublePressDetector {
        DoublePressDetector(shortcut: .commandC, interval: interval)
    }

    func testCommandCTwiceWithinIntervalTriggers() {
        var d = detector()
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 10.0))
        XCTAssertTrue(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 10.3))
    }

    func testSinglePressDoesNothing() {
        var d = detector()
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 1))
    }

    func testTooSlowDoesNotTrigger() {
        var d = detector()
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 10.0))
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 10.6))
        // ...but the late press starts a new sequence.
        XCTAssertTrue(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 10.8))
    }

    func testAutoRepeatIsIgnored() {
        var d = detector()
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 1.0))
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: true, timestamp: 1.1))
        XCTAssertTrue(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 1.2))
    }

    func testOtherKeyInBetweenCancels() {
        var d = detector()
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 1.0))
        XCTAssertFalse(d.handleKeyDown(keyCode: v, modifiers: .command, isRepeat: false, timestamp: 1.1))
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 1.2))
    }

    func testExtraModifiersDoNotMatch() {
        var d = detector()
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: [.command, .shift], isRepeat: false, timestamp: 1.0))
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: [.command, .shift], isRepeat: false, timestamp: 1.1))
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: [], isRepeat: false, timestamp: 1.2))
    }

    func testCapsLockAndFunctionAreIgnored() {
        var d = detector()
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: [.command, .capsLock], isRepeat: false, timestamp: 1.0))
        XCTAssertTrue(d.handleKeyDown(keyCode: c, modifiers: [.command, .function], isRepeat: false, timestamp: 1.2))
    }

    func testTriplePressTriggersOnce() {
        var d = detector()
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 1.0))
        XCTAssertTrue(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 1.2))
        XCTAssertFalse(d.handleKeyDown(keyCode: c, modifiers: .command, isRepeat: false, timestamp: 1.4))
    }

    func testCustomShortcut() {
        var d = DoublePressDetector(
            shortcut: DoublePressShortcut(keyCode: UInt16(kVK_ANSI_T), modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue, keyLabel: "T"),
            interval: 0.45)
        XCTAssertFalse(d.handleKeyDown(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .option], isRepeat: false, timestamp: 1.0))
        XCTAssertTrue(d.handleKeyDown(keyCode: UInt16(kVK_ANSI_T), modifiers: [.command, .option], isRepeat: false, timestamp: 1.3))
    }

    func testShortcutDisplayString() {
        XCTAssertEqual(DoublePressShortcut.commandC.displayString, "⌘ + C + C")
        XCTAssertTrue(DoublePressShortcut.commandC.isCopyShortcut)
    }

    func testPreferredTargetSwitchesWhenSourceIsPrimary() {
        XCTAssertEqual(LanguageRouting.preferredTarget(detected: "en", primary: "ja", secondary: "en"), "ja")
        XCTAssertEqual(LanguageRouting.preferredTarget(detected: "ja", primary: "ja", secondary: "en"), "en")
        XCTAssertEqual(LanguageRouting.preferredTarget(detected: nil, primary: "ja", secondary: "en"), "ja")
        XCTAssertEqual(LanguageRouting.preferredTarget(detected: "ja", primary: "ja-easy", secondary: "en"), "en")
    }
}
