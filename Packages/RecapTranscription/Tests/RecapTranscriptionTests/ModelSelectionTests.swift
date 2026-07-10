import Testing
@testable import RecapTranscription

@Suite struct ModelSelectionTests {
    private let appleSilicon = HardwareProfile(isAppleSilicon: true, physicalMemoryGB: 16)
    private let intel = HardwareProfile(isAppleSilicon: false, physicalMemoryGB: 16)

    // MARK: quality × hardware matrix

    @Test func appleSiliconBestQualityIsLargeV3Turbo() {
        #expect(ModelSelection.model(for: .bestQuality, hardware: appleSilicon).id == "large-v3-v20240930_626MB")
    }

    @Test func appleSiliconFasterIsSmall() {
        #expect(ModelSelection.model(for: .faster, hardware: appleSilicon).id == "small")
    }

    @Test func intelBestQualityIsSmall() {
        #expect(ModelSelection.model(for: .bestQuality, hardware: intel).id == "small")
    }

    @Test func intelFasterIsBase() {
        #expect(ModelSelection.model(for: .faster, hardware: intel).id == "base")
    }

    // MARK: catalog-drift contract

    /// Guards against the `model(for:hardware:)` switch naming a model id
    /// that no longer exists in `ModelCatalog.all` (e.g. after a catalog
    /// rename) — every combo must resolve to a real catalog entry, not just
    /// fall back silently at runtime.
    @Test func everyHardwareQualityComboResolvesToACatalogEntry() {
        let hardwareProfiles = [appleSilicon, intel]
        for hardware in hardwareProfiles {
            for quality in TranscriptionQuality.allCases {
                let resolved = ModelSelection.model(for: quality, hardware: hardware)
                #expect(
                    ModelCatalog.all.contains(where: { $0.id == resolved.id }),
                    "\(hardware) / \(quality) resolved to '\(resolved.id)', which is missing from ModelCatalog.all"
                )
            }
        }
    }

    // MARK: quality(inferredFrom:)

    @Test func inferredQualityForEveryCatalogID() {
        #expect(ModelSelection.quality(inferredFrom: "tiny") == .faster)
        #expect(ModelSelection.quality(inferredFrom: "base") == .faster)
        #expect(ModelSelection.quality(inferredFrom: "small") == .faster)
        #expect(ModelSelection.quality(inferredFrom: "large-v3-v20240930_626MB") == .bestQuality)
    }

    // MARK: reconcile

    @Test func reconcileFreshInstallDownloadsWithNothingToDelete() {
        let plan = ModelSelection.reconcile(
            quality: .bestQuality, hardware: appleSilicon, installedIDs: [], activeID: nil
        )
        #expect(plan == .download(ModelCatalog.info(for: "large-v3-v20240930_626MB")!, thenDelete: []))
    }

    @Test func reconcileTargetAlreadyInstalledIsReadyWithNothingToDelete() {
        let plan = ModelSelection.reconcile(
            quality: .bestQuality, hardware: appleSilicon,
            installedIDs: ["large-v3-v20240930_626MB"], activeID: "large-v3-v20240930_626MB"
        )
        #expect(plan == .ready(activate: "large-v3-v20240930_626MB", deleteOthers: []))
    }

    @Test func reconcileQualitySwitchDownloadsNewTargetAndDeletesOld() {
        // Currently on "faster" (small) on Apple Silicon; switching to
        // "best quality" (large) should download the large model and queue
        // the now-unused small model for deletion.
        let plan = ModelSelection.reconcile(
            quality: .bestQuality, hardware: appleSilicon, installedIDs: ["small"], activeID: "small"
        )
        #expect(plan == .download(ModelCatalog.info(for: "large-v3-v20240930_626MB")!, thenDelete: ["small"]))
    }

    @Test func reconcileTargetInstalledAlongsideOthersDeletesTheOthers() {
        let plan = ModelSelection.reconcile(
            quality: .faster, hardware: appleSilicon,
            installedIDs: ["small", "large-v3-v20240930_626MB", "tiny"], activeID: "large-v3-v20240930_626MB"
        )
        #expect(plan == .ready(activate: "small", deleteOthers: ["tiny", "large-v3-v20240930_626MB"]))
    }
}
