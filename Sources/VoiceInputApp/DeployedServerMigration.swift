import Foundation

enum DeployedServerMigration {
    static let legacyURL = "ws://100.86.28.63:19000/api/voice-input/stream"
    static let previousOrganizedURL = "ws://100.86.28.63:19001/v1/asr/stream"
    static let organizedURL = "ws://100.91.11.111:19001/v1/asr/stream"

    static func migratedURL(from serverURL: String) -> String {
        switch serverURL {
        case legacyURL, previousOrganizedURL: organizedURL
        default: serverURL
        }
    }
}
