import AppKit
import Foundation
import UniformTypeIdentifiers

enum DiagnosticLevel: String, Codable {
    case info
    case warning
    case error
}

struct DiagnosticRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticLevel
    let event: String
    let fields: [String: String]
}

@MainActor
final class DiagnosticsStore: ObservableObject {
    @Published private(set) var records: [DiagnosticRecord] = []
    private let capacity = 300
    private let allowedFields: Set<String> = [
        "mode",
        "source_application",
        "latency_ms",
        "duration_ms",
        "characters",
        "code"
    ]

    func record(_ event: String, fields: [String: String] = [:]) {
        record(.info, event, fields: fields)
    }

    func record(_ level: DiagnosticLevel = .info, _ event: String, fields: [String: String] = [:]) {
        let sanitized = fields.filter { allowedFields.contains($0.key) }
        records.append(DiagnosticRecord(id: UUID(), timestamp: Date(), level: level, event: event, fields: sanitized))
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }

    func clear() {
        records.removeAll(keepingCapacity: true)
    }

    func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "voice-input-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: url, options: .atomic)
        } catch {
            record(.error, "diagnostics_export_failed")
        }
    }
}
