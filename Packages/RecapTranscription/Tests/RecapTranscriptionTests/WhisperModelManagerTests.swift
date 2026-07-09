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
}
