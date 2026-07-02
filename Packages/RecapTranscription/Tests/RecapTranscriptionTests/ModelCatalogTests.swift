import Testing
@testable import RecapTranscription

@Suite struct ModelCatalogTests {
    @Test func recommendedModelIsWhisperSmall() {
        #expect(ModelCatalog.recommended.id == "openai_whisper-small")
    }

    @Test func catalogIDsAreUnique() {
        let ids = ModelCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
