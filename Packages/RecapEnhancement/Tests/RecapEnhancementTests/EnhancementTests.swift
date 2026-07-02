import Testing
import RecapCore
@testable import RecapEnhancement

@Suite struct EnhancementTests {
    @Test func unavailableEnhancerThrows() async {
        let enhancer = UnavailableEnhancer()
        #expect(!enhancer.isAvailable)
        let transcript = Transcript(utterances: [], engine: "whisperkit", model: "test", language: "en")
        await #expect(throws: EnhancementError.unavailable) {
            _ = try await enhancer.enhance(rawNotes: "- notes", transcript: transcript)
        }
    }
}
