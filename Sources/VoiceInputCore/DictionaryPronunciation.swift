import Foundation

public enum DictionaryPronunciation {
    /// Keep the ASR spelling; remove only sentence-ending punctuation from an isolated word.
    public static func spokenForm(from transcript: String) -> String? {
        let sentenceEdges = CharacterSet(charactersIn: "，。！？；,.!?;")
            .union(.whitespacesAndNewlines)
        let spoken = transcript.trimmingCharacters(in: sentenceEdges)
        guard !spoken.isEmpty, spoken.count <= 100 else { return nil }
        return spoken
    }
}
