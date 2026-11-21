import Foundation
import XCTest
@testable import VoiceInput

final class SecureSettingsCodecTests: XCTestCase {
    func testRoundTripUsesRandomAuthenticatedEncryption() throws {
        var keyData: Data?
        let codec = SecureSettingsCodec(
            loadKeyData: { keyData },
            saveKeyData: { keyData = $0 }
        )
        let plaintext = Data(#"{"dictionary":{"private":"value"}}"#.utf8)

        let first = try codec.encrypt(plaintext)
        let second = try codec.encrypt(plaintext)

        XCTAssertNotEqual(first, plaintext)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try codec.decrypt(first), plaintext)
        XCTAssertEqual(try codec.decrypt(second), plaintext)
        XCTAssertEqual(keyData?.count, 32)
    }

    func testTamperingIsRejected() throws {
        var keyData: Data?
        let codec = SecureSettingsCodec(
            loadKeyData: { keyData },
            saveKeyData: { keyData = $0 }
        )
        var encrypted = try codec.encrypt(Data("private settings".utf8))
        encrypted[encrypted.index(before: encrypted.endIndex)] ^= 0x01

        XCTAssertThrowsError(try codec.decrypt(encrypted)) { error in
            XCTAssertEqual(error as? SecureSettingsError, .invalidEncryptedFile)
        }
    }

    func testMissingKeyDoesNotGenerateAReplacementDuringDecryption() throws {
        var storedKey: Data?
        let writer = SecureSettingsCodec(
            loadKeyData: { storedKey },
            saveKeyData: { storedKey = $0 }
        )
        let encrypted = try writer.encrypt(Data("private settings".utf8))
        storedKey = nil
        var saveCount = 0
        let reader = SecureSettingsCodec(
            loadKeyData: { nil },
            saveKeyData: { _ in saveCount += 1 }
        )

        XCTAssertThrowsError(try reader.decrypt(encrypted)) { error in
            XCTAssertEqual(error as? SecureSettingsError, .encryptionKeyMissing)
        }
        XCTAssertEqual(saveCount, 0)
    }
}
