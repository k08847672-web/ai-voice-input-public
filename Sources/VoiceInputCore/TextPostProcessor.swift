import Foundation

public enum TextPostProcessor {
    public static func applyDictionary(_ dictionary: [DictionaryEntry], to text: String) -> String {
        let replacements = dictionary.reduce(into: [String: String]()) { result, entry in
            if !entry.spoken.isEmpty, entry.spoken != entry.written {
                result[entry.spoken] = entry.written
            }
        }
        let ordered = replacements.sorted { $0.key.count > $1.key.count }
        guard !ordered.isEmpty else { return text }

        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let remaining = text[index...]
            if let match = ordered.first(where: { remaining.hasPrefix($0.key) }) {
                result += match.value
                index = text.index(index, offsetBy: match.key.count)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    public static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[ \\t]+([，。！？；：,.!?;:])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
