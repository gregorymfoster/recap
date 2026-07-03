import Foundation
import Observation
import WhisperKit

public enum ModelState: Equatable, Sendable {
    /// Not on disk.
    case available
    case downloading(progress: Double)
    case installed
}

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
    /// The dedicated light model used for the live (streaming) pass during
    /// recording — independent of `activeModelID`, which drives the
    /// canonical post-stop file pass. Defaults to Whisper Tiny: small enough
    /// to load fast and keep up with a 4s realtime loop even when the file
    /// pass model is something heavy like Large v3 Turbo.
    public private(set) var streamingModelID: String

    private let modelsRoot: URL
    private let defaults: UserDefaults
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    private static let activeModelKey = "activeModelID"
    private static let streamingModelKey = "streamingModelID"

    public static var defaultModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recap/Models")
    }

    public init(modelsRoot: URL = WhisperModelManager.defaultModelsRoot, defaults: UserDefaults = .standard) {
        self.modelsRoot = modelsRoot
        self.defaults = defaults
        activeModelID = defaults.string(forKey: Self.activeModelKey)
        streamingModelID = defaults.string(forKey: Self.streamingModelKey) ?? ModelCatalog.streamingDefault.id
        refresh()
    }

    public var activeModel: ModelInfo? {
        activeModelID.flatMap(ModelCatalog.info(for:))
    }

    public var streamingModel: ModelInfo? {
        ModelCatalog.info(for: streamingModelID)
    }

    /// Local folder of an installed model, or nil if not fully downloaded.
    public func installedFolder(for model: ModelInfo) -> URL? {
        let folder = snapshotFolder(for: model)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              // A usable WhisperKit model folder contains compiled CoreML bundles.
              let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
              contents.contains(where: { $0.hasSuffix(".mlmodelc") })
        else { return nil }
        return folder
    }

    /// Re-derives every model's state from disk.
    public func refresh() {
        for model in ModelCatalog.all {
            if case .downloading = states[model.id] { continue }
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
        downloadTasks[model.id] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await WhisperKit.download(
                    variant: model.id,
                    downloadBase: root,
                    useBackgroundSession: false
                ) { progress in
                    let fraction = progress.fractionCompleted
                    Task { @MainActor in
                        self.setDownloadProgress(fraction, for: model)
                    }
                }
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

    /// Changes the dedicated live-pass model. Persisted separately from
    /// `activeModelID` so switching the file-pass model never disturbs it.
    public func setStreamingModel(_ id: String) {
        streamingModelID = id
        defaults.set(id, forKey: Self.streamingModelKey)
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

    /// The engine for the dedicated streaming model, if one is installed.
    /// Independent of `activeEngine()` — a second WhisperKit instance, kept
    /// deliberately light so it can keep up with the realtime loop even when
    /// the file-pass model is large. If the streaming and active models
    /// happen to be the same variant, the two engines simply point at the
    /// same folder; each still loads its own WhisperKit instance.
    ///
    /// - Parameter language: See `activeEngine(language:)`.
    public func streamingEngine(language: String? = nil) -> WhisperKitEngine? {
        guard let model = streamingModel, let folder = installedFolder(for: model) else { return nil }
        return WhisperKitEngine(
            modelFolder: folder, modelName: model.repoFolderName,
            language: model.isEnglishOnly ? nil : language,
            downloadBase: modelsRoot
        )
    }

    /// True once the streaming model is installed and ready to use.
    public var isStreamingModelInstalled: Bool {
        guard let model = streamingModel else { return false }
        return states[model.id] == .installed
    }

    /// Starts downloading the streaming model if it isn't already installed
    /// or in flight. Safe to call unconditionally (e.g. on first recording).
    public func ensureStreamingModelDownloading() {
        guard let model = streamingModel, !isStreamingModelInstalled else { return }
        download(model)
    }

    // MARK: Private

    private func finishDownload(of model: ModelInfo, failed: Bool) {
        downloadTasks[model.id] = nil
        refreshState(of: model)
        // First installed model becomes active automatically.
        if !failed, activeModelID == nil, states[model.id] == .installed {
            setActive(model.id)
        }
    }

    private func refreshState(of model: ModelInfo) {
        states[model.id] = installedFolder(for: model) != nil ? .installed : .available
    }

    private func snapshotFolder(for model: ModelInfo) -> URL {
        modelsRoot
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.repoFolderName)
    }
}
