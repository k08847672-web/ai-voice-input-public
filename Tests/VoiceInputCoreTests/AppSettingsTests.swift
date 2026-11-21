import XCTest
@testable import VoiceInputCore

final class AppSettingsTests: XCTestCase {
    func testProfileOverridesDefaultMode() {
        var settings = AppSettings(defaultMode: .faithful)
        settings.appProfiles = [
            AppProfile(
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit",
                mode: .smart,
                style: "简洁"
            )
        ]

        let matched = settings.resolvedProfile(for: "com.apple.TextEdit")
        XCTAssertEqual(matched.mode, .smart)
        XCTAssertEqual(matched.style, "简洁")
        XCTAssertEqual(settings.resolvedProfile(for: "com.apple.Terminal").mode, .faithful)
    }

    func testSettingsRoundTrip() throws {
        let settings = AppSettings(
            serverURL: "wss://asr.example.com/v1/asr/stream",
            hotKey: HotKeyDescriptor(activationMode: .toggle),
            hotwords: ["Codex"],
            dictionary: [DictionaryEntry(spoken: "扣得克斯", written: "Codex")]
        )
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), settings)
    }

    func testLegacyHotKeyDefaultsToPressAndHold() throws {
        let legacy = Data(#"{"keyCode":49,"modifiers":1179648}"#.utf8)
        let hotKey = try JSONDecoder().decode(HotKeyDescriptor.self, from: legacy)

        XCTAssertEqual(hotKey.activationMode, .pressAndHold)
        XCTAssertEqual(hotKey.displayName, "⌘⇧Space")
    }

    func testNewDefaultAvoidsCommandSpaceShortcut() {
        XCTAssertEqual(HotKeyDescriptor.default.displayName, "⌃⌥Space")
        XCTAssertEqual(HotKeyDescriptor.default.activationMode, .pressAndHold)
    }

    func testCustomShortcutDisplayAndValidation() {
        let controlCommandD = HotKeyDescriptor(keyCode: 2, modifiers: 1_310_720)
        XCTAssertEqual(controlCommandD.displayName, "⌃⌘D")
        XCTAssertTrue(controlCommandD.isValidGlobalShortcut)

        let plainD = HotKeyDescriptor(keyCode: 2, modifiers: 0)
        XCTAssertFalse(plainD.isValidGlobalShortcut)

        let f8 = HotKeyDescriptor(keyCode: 100, modifiers: 0)
        XCTAssertEqual(f8.displayName, "F8")
        XCTAssertTrue(f8.isValidGlobalShortcut)

        let leftCommand = HotKeyDescriptor(keyCode: 55, modifiers: 1_048_576)
        XCTAssertEqual(leftCommand.displayName, "左⌘")
        XCTAssertTrue(leftCommand.isCommandModifierOnly)
        XCTAssertTrue(leftCommand.isValidGlobalShortcut)

        let rightCommand = HotKeyDescriptor(keyCode: 54, modifiers: 1_048_576)
        XCTAssertEqual(rightCommand.displayName, "右⌘")
        XCTAssertTrue(rightCommand.isCommandModifierOnly)
        XCTAssertTrue(rightCommand.isValidGlobalShortcut)

        let commandShift = HotKeyDescriptor(keyCode: 55, modifiers: 1_179_648)
        XCTAssertFalse(commandShift.isCommandModifierOnly)
        XCTAssertFalse(commandShift.isValidGlobalShortcut)
    }
}
