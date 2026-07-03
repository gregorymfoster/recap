import Foundation
import Testing
import WhisperKit
@testable import RecapTranscription

@Suite struct WhisperKitEngineTests {
    @Test func nilLanguageLeavesDefaultsUntouched() {
        let base = DecodingOptions()
        let options = WhisperKitEngine.decodingOptions(language: nil)
        #expect(options.language == base.language)
        #expect(options.detectLanguage == base.detectLanguage)
        #expect(options.task == .transcribe)
        #expect(options.skipSpecialTokens == true)
    }

    @Test func explicitLanguageDisablesAutoDetection() {
        let options = WhisperKitEngine.decodingOptions(language: "es")
        #expect(options.language == "es")
        #expect(options.detectLanguage == false)
    }

    @Test func engineDefaultsToAutoDetectWhenLanguageOmitted() {
        let engine = WhisperKitEngine(modelFolder: URL(filePath: "/dev/null"), modelName: "tiny")
        #expect(engine.language == nil)
    }

    @Test func engineRetainsPassedLanguage() {
        let engine = WhisperKitEngine(modelFolder: URL(filePath: "/dev/null"), modelName: "tiny", language: "fr")
        #expect(engine.language == "fr")
    }
}
