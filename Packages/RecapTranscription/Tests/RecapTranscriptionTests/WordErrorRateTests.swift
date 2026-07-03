import Testing
@testable import RecapTranscription

@Suite struct WordErrorRateTests {
    @Test func bothEmptyIsZero() {
        #expect(WordErrorRate.wer(reference: "", hypothesis: "") == 0.0)
    }

    @Test func emptyReferenceWithNonEmptyHypothesisIsOne() {
        #expect(WordErrorRate.wer(reference: "", hypothesis: "hello world") == 1.0)
    }

    @Test func nonEmptyReferenceWithEmptyHypothesisIsOne() {
        #expect(WordErrorRate.wer(reference: "hello world", hypothesis: "") == 1.0)
    }

    @Test func identicalTextIsZero() {
        #expect(WordErrorRate.wer(reference: "the quick brown fox", hypothesis: "the quick brown fox") == 0.0)
    }

    @Test func caseAndPunctuationDifferencesAreIgnored() {
        let wer = WordErrorRate.wer(
            reference: "The quick, brown fox!",
            hypothesis: "the quick brown fox"
        )
        #expect(wer == 0.0)
    }

    @Test func collapsesRepeatedWhitespace() {
        let wer = WordErrorRate.wer(reference: "hello   world", hypothesis: "hello world")
        #expect(wer == 0.0)
    }

    @Test func oneSubstitution() {
        // "brown" -> "red": 1 substitution / 4 reference words.
        let wer = WordErrorRate.wer(reference: "the quick brown fox", hypothesis: "the quick red fox")
        #expect(wer == 0.25)
    }

    @Test func oneDeletion() {
        // hypothesis drops "quick": 1 deletion / 4 reference words.
        let wer = WordErrorRate.wer(reference: "the quick brown fox", hypothesis: "the brown fox")
        #expect(wer == 0.25)
    }

    @Test func oneInsertion() {
        // hypothesis adds "very": 1 insertion / 4 reference words.
        let wer = WordErrorRate.wer(reference: "the quick brown fox", hypothesis: "the very quick brown fox")
        #expect(wer == 0.25)
    }

    @Test func allWordsDifferentIsOne() {
        let wer = WordErrorRate.wer(reference: "alpha beta gamma", hypothesis: "one two three")
        #expect(wer == 1.0)
    }

    @Test func knownDistanceExample() {
        // reference: 5 words. hypothesis substitutes 2 words -> WER 0.4.
        let wer = WordErrorRate.wer(
            reference: "meet me at the office",
            hypothesis: "meet me by the store"
        )
        #expect(wer == 0.4)
    }
}
