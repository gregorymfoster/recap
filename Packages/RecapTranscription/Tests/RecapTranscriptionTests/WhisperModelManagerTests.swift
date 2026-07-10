import Foundation
import Testing
@testable import RecapTranscription

@MainActor
@Suite struct WhisperModelManagerTests {
    private func makeDefaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "WhisperModelManagerTests-\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: "WhisperModelManagerTests-\(UUID().uuidString)")
        return suite
    }

    private func makeManager(
        defaults: UserDefaults,
        downloader: @escaping ModelDownloader
    ) -> WhisperModelManager {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return WhisperModelManager(modelsRoot: root, defaults: defaults, downloader: downloader)
    }

    @Test func failedDownloadEndsInFailedState() async {
        let manager = makeManager(defaults: makeDefaults()) { _, _, _ in
            struct FakeDownloadError: Error {}
            throw FakeDownloadError()
        }
        let model = ModelCatalog.all[0]
        manager.download(model)
        // The download task runs on the main actor's cooperative pool; yield
        // until it lands.
        for _ in 0..<200 where manager.states[model.id] == .downloading(progress: 0) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.states[model.id] == .failed)
    }

    @Test func successfulDownloadEndsInstalledAndBecomesActive() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = makeDefaults()
        let model = ModelCatalog.all[0]
        let manager = WhisperModelManager(modelsRoot: root, defaults: defaults) { _, downloadBase, _ in
            // Simulate a real download by writing the compiled-model marker
            // WhisperModelManager looks for on disk. Deliberately doesn't
            // call `progressCallback` — that fires on a detached `Task` and
            // isn't ordered against the completion this test cares about.
            let folder = downloadBase
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
                .appendingPathComponent(model.repoFolderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("dummy.mlmodelc"))
        }
        manager.download(model)
        for _ in 0..<200 where manager.states[model.id] != .installed {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.states[model.id] == .installed)
        #expect(manager.activeModelID == model.id)
    }

    @Test func refreshPreservesFailedState() async {
        let manager = makeManager(defaults: makeDefaults()) { _, _, _ in
            struct FakeDownloadError: Error {}
            throw FakeDownloadError()
        }
        let model = ModelCatalog.all[0]
        manager.download(model)
        for _ in 0..<200 where manager.states[model.id] != .failed {
            try? await Task.sleep(for: .milliseconds(5))
        }
        manager.refresh()
        #expect(manager.states[model.id] == .failed)
    }

    /// A download interrupted after only some of a model's compiled bundles
    /// landed on disk (no completion marker, no full required-file set) must
    /// never look installed — that's exactly the "auto-activates, then fails
    /// at record time" bug.
    @Test func partialDownloadIsNotInstalled() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = makeDefaults()
        let model = ModelCatalog.all[0]
        let manager = WhisperModelManager(modelsRoot: root, defaults: defaults) { _, downloadBase, _ in
            let folder = downloadBase
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
                .appendingPathComponent(model.repoFolderName)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Only one of the three bundles WhisperKit requires landed —
            // simulates a download cancelled/interrupted partway through.
            try Data().write(to: folder.appendingPathComponent("AudioEncoder.mlmodelc"))
            struct InterruptedDownloadError: Error {}
            throw InterruptedDownloadError()
        }
        manager.download(model)
        for _ in 0..<200 where manager.states[model.id] == .downloading(progress: 0) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(manager.states[model.id] == .failed)
        #expect(manager.installedFolder(for: model) == nil)
    }

    /// Models downloaded before the completion marker existed have no
    /// marker file but do have every required bundle — `installedFolder`
    /// must still recognize them via the backward-compat file check.
    @Test func preMarkerCompleteDownloadIsStillRecognizedAsInstalled() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = makeDefaults()
        let model = ModelCatalog.all[0]
        let manager = WhisperModelManager(modelsRoot: root, defaults: defaults) { _, _, _ in
            struct UnusedError: Error {}
            throw UnusedError()
        }
        let folder = root
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.repoFolderName)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try? Data().write(to: folder.appendingPathComponent("\(name).mlmodelc"))
        }
        manager.refresh()
        #expect(manager.states[model.id] == .installed)
        #expect(manager.installedFolder(for: model)?.path == folder.path)
    }

    @Test func pausingDoesNotEndInFailedState() async {
        let manager = makeManager(defaults: makeDefaults()) { _, _, _ in
            // Simulates a slow download: cancellation surfaces as
            // `CancellationError` thrown out of `Task.sleep`, exercising the
            // same catch-block path a real cancelled download would take.
            try await Task.sleep(for: .seconds(5))
        }
        let model = ModelCatalog.all[0]
        manager.download(model)
        // Let the task start running before pausing it.
        for _ in 0..<200 where manager.states[model.id] == .available {
            try? await Task.sleep(for: .milliseconds(5))
        }
        manager.pauseDownload(of: model)
        #expect(manager.states[model.id] == .available)
        // Give the cancelled task's `catch` block time to run and confirm it
        // doesn't clobber the paused state with `.failed`.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(manager.states[model.id] == .available)
    }
}

@MainActor
@Suite struct WhisperModelInstallCompletenessTests {
    private static let requiredBaseNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    @Test func markerAloneIsSufficientRegardlessOfContents() {
        #expect(WhisperModelManager.isCompleteInstall(contents: [], hasCompletionMarker: true))
        #expect(WhisperModelManager.isCompleteInstall(contents: ["junk"], hasCompletionMarker: true))
    }

    @Test func noMarkerAndEmptyFolderIsIncomplete() {
        #expect(!WhisperModelManager.isCompleteInstall(contents: [], hasCompletionMarker: false))
    }

    @Test func noMarkerRequiresAllThreeBundles() {
        #expect(!WhisperModelManager.isCompleteInstall(
            contents: ["AudioEncoder.mlmodelc"], hasCompletionMarker: false
        ))
        #expect(!WhisperModelManager.isCompleteInstall(
            contents: ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"], hasCompletionMarker: false
        ))
        #expect(WhisperModelManager.isCompleteInstall(
            contents: Set(Self.requiredBaseNames.map { "\($0).mlmodelc" }), hasCompletionMarker: false
        ))
    }

    @Test func noMarkerAcceptsMlpackageVariants() {
        #expect(WhisperModelManager.isCompleteInstall(
            contents: Set(Self.requiredBaseNames.map { "\($0).mlpackage" }), hasCompletionMarker: false
        ))
    }

    @Test func noMarkerAcceptsMixOfCompiledAndPackageBundles() {
        #expect(WhisperModelManager.isCompleteInstall(
            contents: [
                "MelSpectrogram.mlmodelc",
                "AudioEncoder.mlpackage",
                "TextDecoder.mlmodelc",
            ],
            hasCompletionMarker: false
        ))
    }

    @Test func noMarkerIgnoresUnrelatedExtraFiles() {
        #expect(WhisperModelManager.isCompleteInstall(
            contents: Set(Self.requiredBaseNames.map { "\($0).mlmodelc" } + ["config.json", "tokenizer.json"]),
            hasCompletionMarker: false
        ))
    }
}
