import Testing
@testable import RecapTranscription

@Suite struct ModelCatalogTests {
    @Test func recommendedModelIsWhisperLargeV3Turbo() {
        #expect(ModelCatalog.recommended.id == "large-v3-v20240930_626MB")
        #expect(ModelCatalog.recommended.repoFolderName == "openai_whisper-large-v3-v20240930_626MB")
    }

    @Test func catalogIDsAreUnique() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
