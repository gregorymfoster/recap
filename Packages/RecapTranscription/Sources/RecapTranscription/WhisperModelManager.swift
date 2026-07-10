import Foundation
import Observation
import WhisperKit

public enum ModelState: Equatable, Sendable {
    /// Not on disk.
    case available
    case downloading(progress: Double)
    case installed
    /// The last download attempt failed (network error, corrupt snapshot,
    /// etc.). Distinct from `.available` so callers (e.g.
    /// `TranscriptionSetupStore`) can show/retry a failure instead of
    /// silently looking like the download never happened.
    case failed
}

/// Downloads a model variant into `downloadBase`, reporting fractional
/// progress via `progressCallback`. The production default forwards to
/// `WhisperKit.download`; tests inject a closure that succeeds/fails
/// instantly without touching the network.
public typealias ModelDownloader = @Sendable (
    _ variant: String,
    _ downloadBase: URL,
    _ progressCallback: @escaping @Sendable (Double) -> Void
) async throws -> Void

/// Downloads, tracks, and activates WhisperKit models on disk.
///
/// Models live under `~/Library/Application Support/Recap/Models` in the
/// HubApi snapshot layout. Downloads are incremental per file, so a cancelled
/// (paused) download resumes where it left off when restarted.
@MainActor
@Observable
public final class WhisperModelManager {
    public private(set) var states: [String: ModelState] = [:]
    public private(set) var activeModelID: String?

    private let modelsRoot: URL
    private let defaults: UserDefaults
    private let downloader: ModelDownloader
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    private static let activeModelKey = "activeModelID"
    /// No longer used — the dedicated streaming/live-pass model was removed
    /// in favor of automatic quality-driven selection. Cleared once at init
    /// so a stale value doesn't linger in defaults forever.
    private static let legacyStreamingModelKey = "streamingModelID"

    /// Written into a model's snapshot folder the moment its download
    /// completes successfully. `installedFolder` requires this marker (or
    /// the backward-compat file check below) before calling a folder
    /// installed — a folder containing only *some* of a model's compiled
    /// bundles (a download interrupted partway through) must never look
    /// installed, or `WhisperKit(config)` fails at record time instead of
    /// at download time.
    static let completionMarkerName = ".recap-complete"

    /// Models the user has explicitly paused mid-download. `pauseDownload`
    /// inserts before cancelling; `finishDownload` consults (and clears) it
    /// so the cancelled task's own `catch` — which still runs after the
    /// state has already been reset to `.available`/`.installed` — doesn't
    /// clobber that with `.failed`.
    private var pausedModelIDs: Set<String> = []

    public static var defaultModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recap/Models")
    }

    public init(
        modelsRoot: URL = WhisperModelManager.defaultModelsRoot,
        defaults: UserDefaults = .standard,
        downloader: @escaping ModelDownloader = WhisperModelManager.defaultDownloader
    ) {
        self.modelsRoot = modelsRoot
        self.defaults = defaults
        self.downloader = downloader
        activeModelID = defaults.string(forKey: Self.activeModelKey)
        defaults.removeObject(forKey: Self.legacyStreamingModelKey)
        refresh()
    }

    /// Forwards to `WhisperKit.download`, translating `Progress` into a bare
    /// fraction.
    public static let defaultDownloader: ModelDownloader = { variant, downloadBase, progressCallback in
        _ = try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase,
            useBackgroundSession: false
        ) { progress in
            progressCallback(progress.fractionCompleted)
        }
    }

    public var activeModel: ModelInfo? {
        activeModelID.flatMap(ModelCatalog.info(for:))
    }

    /// Local folder of an installed model, or nil if not fully downloaded.
    public func installedFolder(for model: ModelInfo) -> URL? {
        let folder = snapshotFolder(for: model)
        return Self.isCompleteInstall(at: folder) ? folder : nil
    }

    /// Disk-touching half of the completeness check: reads the folder's
    /// contents and the presence of the completion marker, then defers to
    /// the pure `isCompleteInstall(contents:hasCompletionMarker:)` below.
    static func isCompleteInstall(at folder: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        else { return false }
        let contentSet = Set(contents)
        return isCompleteInstall(
            contents: contentSet,
            hasCompletionMarker: contentSet.contains(completionMarkerName)
        )
    }

    /// Pure logic: does a snapshot folder's contents amount to a complete,
    /// loadable WhisperKit model?
    ///
    /// - Preferred path: the `.recap-complete` marker, written only once a
    ///   download finishes successfully. A folder with the marker is
    ///   installed no matter what else is (or isn't) in it.
    /// - Backward-compat path: models downloaded before the marker existed
    ///   have no marker but are otherwise complete. `WhisperKit.loadModels`
    ///   (see `WhisperKit.swift`) requires exactly three named CoreML
    ///   bundles at the folder's top level — `MelSpectrogram`,
    ///   `AudioEncoder`, `TextDecoder`, each either compiled (`.mlmodelc`)
    ///   or a source package (`.mlpackage`) — plus a tokenizer, which
    ///   WhisperKit resolves separately at load time. Treating "all three
    ///   model bundles present" as "fully downloaded" is a heuristic, not a
    ///   guarantee (a download could in principle be interrupted after all
    ///   three land but before some other file), but it's a much tighter
    ///   bar than "any one `.mlmodelc`" and matches what WhisperKit itself
    ///   requires to load.
    static func isCompleteInstall(contents: Set<String>, hasCompletionMarker: Bool) -> Bool {
        if hasCompletionMarker { return true }
        let requiredBaseNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        return requiredBaseNames.allSatisfy { name in
            contents.contains("\(name).mlmodelc") || contents.contains("\(name).mlpackage")
        }
    }

    /// Re-derives every model's state from disk. Leaves `.downloading` and
    /// `.failed` states alone — those are session-lived facts refresh can't
    /// re-derive from disk alone (a failed attempt still isn't installed).
    public func refresh() {
        for model in ModelCatalog.all {
            if case .downloading = states[model.id] { continue }
            if case .failed = states[model.id] { continue }
            states[model.id] = installedFolder(for: model) != nil ? .installed : .available
        }
        if let activeModelID, states[activeModelID] != .installed {
            setActive(nil)
        }
    }

    public func download(_ model: ModelInfo) {
        guard downloadTasks[model.id] == nil else { return }
        states[model.id] = .downloading(progress: 0)
        let root = modelsRoot
        let downloader = downloader
        downloadTasks[model.id] = Task { [weak self] in
            guard let self else { return }
            do {
                try await downloader(model.id, root) { fraction in
                    Task { @MainActor in
                        self.setDownloadProgress(fraction, for: model)
                    }
                }
                self.markInstallComplete(for: model)
                self.finishDownload(of: model, failed: false)
            } catch {
                self.finishDownload(of: model, failed: true)
            }
        }
    }

    private func setDownloadProgress(_ fraction: Double, for model: ModelInfo) {
        if case .downloading = states[model.id] {
            states[model.id] = .downloading(progress: fraction)
        }
    }

    /// Cancels an in-flight download. Already-fetched files stay on disk, so
    /// a later `download` resumes from there.
    public func pauseDownload(of model: ModelInfo) {
        pausedModelIDs.insert(model.id)
        downloadTasks[model.id]?.cancel()
        downloadTasks[model.id] = nil
        refreshState(of: model)
    }

    public func delete(_ model: ModelInfo) {
        guard downloadTasks[model.id] == nil else { return }
        try? FileManager.default.removeItem(at: snapshotFolder(for: model))
        if activeModelID == model.id {
            setActive(nil)
        }
        refreshState(of: model)
    }

    public func setActive(_ id: String?) {
        activeModelID = id
        if let id {
            defaults.set(id, forKey: Self.activeModelKey)
        } else {
            defaults.removeObject(forKey: Self.activeModelKey)
        }
    }

    /// The engine for the active model, if one is installed.
    ///
    /// - Parameter language: Forces decoding to this language (ISO 639-1
    ///   code); `nil` auto-detects. Ignored (forced to `nil`) for
    ///   English-only models — forcing a language on a model that only
    ///   understands English would just be a no-op at best, and WhisperKit
    ///   has no other language to switch to.
    public func activeEngine(language: String? = nil) -> WhisperKitEngine? {
        guard let model = activeModel, let folder = installedFolder(for: model) else { return nil }
        return WhisperKitEngine(
            modelFolder: folder, modelName: model.repoFolderName,
            language: model.isEnglishOnly ? nil : language,
            downloadBase: modelsRoot
        )
    }

    // MARK: Private

    private func finishDownload(of model: ModelInfo, failed: Bool) {
        downloadTasks[model.id] = nil
        // Cancelling a task for a deliberate pause still runs the
        // downloader's `catch` (it observes cancellation as a thrown
        // error), which would otherwise land here with `failed: true` and
        // stomp the `.available`/`.installed` state `pauseDownload` already
        // set. A pause isn't a failure, so skip straight to re-deriving
        // from disk instead of forcing `.failed`.
        let wasPaused = pausedModelIDs.remove(model.id) != nil
        if failed {
            if wasPaused {
                refreshState(of: model)
                return
            }
            // A failed attempt may still have left a complete snapshot from
            // an earlier successful download — trust disk over the network
            // outcome.
            states[model.id] = installedFolder(for: model) != nil ? .installed : .failed
            return
        }
        refreshState(of: model)
        // First installed model becomes active automatically.
        if activeModelID == nil, states[model.id] == .installed {
            setActive(model.id)
        }
    }

    private func refreshState(of model: ModelInfo) {
        states[model.id] = installedFolder(for: model) != nil ? .installed : .available
    }

    /// Marks a snapshot folder as a fully, successfully downloaded model.
    /// Called once, right after the downloader returns without throwing.
    private func markInstallComplete(for model: ModelInfo) {
        let markerPath = snapshotFolder(for: model)
            .appendingPathComponent(Self.completionMarkerName).path
        FileManager.default.createFile(atPath: markerPath, contents: Data())
    }

    private func snapshotFolder(for model: ModelInfo) -> URL {
        modelsRoot
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.repoFolderName)
    }
}
