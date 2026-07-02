import Foundation

/// A downloadable speech model the user can install via the Model Manager.
public struct ModelInfo: Identifiable, Equatable, Sendable {
    /// WhisperKit variant name, as passed to `WhisperKitConfig(model:)` /
    /// `WhisperKit.download(variant:)`.
    public var id: String
    public var displayName: String
    public var approximateSizeMB: Int
    public var languages: String
    public var qualityHint: String
    public var isRecommended: Bool

    public init(
        id: String,
        displayName: String,
        approximateSizeMB: Int,
        languages: String,
        qualityHint: String,
        isRecommended: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.approximateSizeMB = approximateSizeMB
        self.languages = languages
        self.qualityHint = qualityHint
        self.isRecommended = isRecommended
    }

    /// Folder name inside the whisperkit-coreml repo snapshot.
    public var repoFolderName: String { "openai_whisper-\(id)" }
}

/// Static catalog of WhisperKit CoreML builds hosted at huggingface.co/argmaxinc/whisperkit-coreml.
public enum ModelCatalog {
    public static let all: [ModelInfo] = [
        ModelInfo(id: "tiny", displayName: "Whisper Tiny", approximateSizeMB: 80,
                  languages: "Multilingual", qualityHint: "Fastest · rough drafts"),
        ModelInfo(id: "base", displayName: "Whisper Base", approximateSizeMB: 150,
                  languages: "Multilingual", qualityHint: "Fast · casual notes"),
        ModelInfo(id: "small", displayName: "Whisper Small", approximateSizeMB: 500,
                  languages: "Multilingual", qualityHint: "Balanced · recommended", isRecommended: true),
        ModelInfo(id: "medium", displayName: "Whisper Medium", approximateSizeMB: 1500,
                  languages: "Multilingual", qualityHint: "Accurate · slower"),
        ModelInfo(id: "large-v3-v20240930_626MB", displayName: "Whisper Large v3 Turbo",
                  approximateSizeMB: 626,
                  languages: "Multilingual", qualityHint: "Most accurate · compressed"),
    ]

    public static var recommended: ModelInfo {
        all.first(where: \.isRecommended)!
    }

    public static func info(for id: String) -> ModelInfo? {
        all.first { $0.id == id }
    }
}
