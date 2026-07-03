import Testing
@testable import RecapUI

@Suite struct ModelDiskSpaceTests {
    @Test func fitsWhenFreeSpaceExceedsModelSize() {
        let oneGB: Int64 = 1_000_000_000
        #expect(ModelDiskSpace.wontFit(freeBytes: oneGB, modelSizeMB: 500) == false)
    }

    @Test func wontFitWhenFreeSpaceIsBelowModelSize() {
        let underOneGB: Int64 = 400_000_000
        #expect(ModelDiskSpace.wontFit(freeBytes: underOneGB, modelSizeMB: 626) == true)
    }

    @Test func exactlyEnoughSpaceFits() {
        let exact: Int64 = 626_000_000
        #expect(ModelDiskSpace.wontFit(freeBytes: exact, modelSizeMB: 626) == false)
    }

    @Test func unknownFreeSpaceNeverWarns() {
        #expect(ModelDiskSpace.wontFit(freeBytes: nil, modelSizeMB: 626) == false)
    }

    @Test func footnoteIsNilWhenModelFits() {
        let plentyOfSpace: Int64 = 10_000_000_000
        #expect(ModelDiskSpace.footnote(freeBytes: plentyOfSpace, modelSizeMB: 626, modelDisplayName: "Whisper Large v3 Turbo") == nil)
    }

    @Test func footnoteIsNilWhenFreeSpaceUnknown() {
        #expect(ModelDiskSpace.footnote(freeBytes: nil, modelSizeMB: 626, modelDisplayName: "Whisper Large v3 Turbo") == nil)
    }

    @Test func footnoteNamesTheModelAndItsNeededSize() {
        let tightSpace: Int64 = 400_000_000
        let footnote = ModelDiskSpace.footnote(freeBytes: tightSpace, modelSizeMB: 626, modelDisplayName: "Whisper Large v3 Turbo")
        #expect(footnote != nil)
        #expect(footnote?.contains("Whisper Large v3 Turbo needs 626 MB") == true)
        #expect(footnote?.contains("free on disk") == true)
    }
}
