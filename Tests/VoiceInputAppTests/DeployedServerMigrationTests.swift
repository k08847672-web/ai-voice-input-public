import XCTest
@testable import VoiceInput

final class DeployedServerMigrationTests: XCTestCase {
    func testMigratesOnlyTheDeployedLegacyEndpoint() {
        XCTAssertEqual(
            DeployedServerMigration.migratedURL(from: DeployedServerMigration.legacyURL),
            DeployedServerMigration.organizedURL
        )
        XCTAssertEqual(
            DeployedServerMigration.migratedURL(from: DeployedServerMigration.previousOrganizedURL),
            DeployedServerMigration.organizedURL
        )
        XCTAssertEqual(
            DeployedServerMigration.migratedURL(from: "wss://example.com/v1/asr/stream"),
            "wss://example.com/v1/asr/stream"
        )
        XCTAssertEqual(
            DeployedServerMigration.migratedURL(from: "ws://100.100.97.120:8765/api/voice-input/stream"),
            "ws://100.100.97.120:8765/api/voice-input/stream"
        )
    }
}
