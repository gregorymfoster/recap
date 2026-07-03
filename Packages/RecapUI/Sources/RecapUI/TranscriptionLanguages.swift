import Foundation

/// Curated language list for the "Transcription language" Settings picker —
/// common WhisperKit languages, rather than every ISO code Whisper supports.
public enum TranscriptionLanguages {
    public struct Language: Identifiable, Sendable {
        public var code: String
        public var displayName: String

        public var id: String { code }
    }

    /// ISO 639-1 codes, in the order they should appear in the picker.
    public static let common: [Language] = [
        "en", "es", "fr", "de", "it", "pt", "nl", "ja", "zh", "ko",
        "ru", "hi", "ar", "tr", "pl", "sv", "uk", "vi",
    ].map { code in
        Language(code: code, displayName: Locale.current.localizedString(forLanguageCode: code) ?? code)
    }
}
