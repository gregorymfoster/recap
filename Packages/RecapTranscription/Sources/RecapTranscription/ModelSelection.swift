import Foundation
import os
#if canImport(Darwin)
import Darwin
#endif

private let modelSelectionLog = Logger(subsystem: "com.gregfoster.recap", category: "ModelSelection")

/// Hardware facts `ModelSelection` picks a model against — Apple Silicon vs.
/// Intel, and installed RAM (models scale down on lower-memory machines).
public struct HardwareProfile: Equatable, Sendable {
    public var isAppleSilicon: Bool
    public var physicalMemoryGB: Int

    public init(isAppleSilicon: Bool, physicalMemoryGB: Int) {
        self.isAppleSilicon = isAppleSilicon
        self.physicalMemoryGB = physicalMemoryGB
    }

    /// Reads the running machine's actual hardware via `sysctlbyname` +
    /// `ProcessInfo`.
    public static func current() -> HardwareProfile {
        HardwareProfile(isAppleSilicon: currentIsAppleSilicon(), physicalMemoryGB: currentPhysicalMemoryGB())
    }

    private static func currentIsAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return status == 0 && value == 1
    }

    private static func currentPhysicalMemoryGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }
}

/// User-facing transcription quality preference — maps down to a concrete
/// `ModelInfo` via `ModelSelection.model(for:hardware:)`.
public enum TranscriptionQuality: String, CaseIterable, Codable, Sendable {
    case bestQuality
    case faster
}

/// Resolves a `TranscriptionQuality` + `HardwareProfile` pair to a concrete
/// catalog model, infers quality back from an installed model id, and plans
/// the download/activation/cleanup steps needed to move to a new quality
/// (Phase 0 scaffolding for the model-quality-picker redesign).
public enum ModelSelection {
    /// Which model backs each quality tier, per hardware class:
    /// Apple Silicon best = Whisper Large v3 Turbo, faster = Small;
    /// Intel best = Small, faster = Base.
    public static func model(for quality: TranscriptionQuality, hardware: HardwareProfile) -> ModelInfo {
        let id: String
        switch (hardware.isAppleSilicon, quality) {
        case (true, .bestQuality): id = "large-v3-v20240930_626MB"
        case (true, .faster): id = "small"
        case (false, .bestQuality): id = "small"
        case (false, .faster): id = "base"
        }
        // Every branch above names a real `ModelCatalog.all` id; a missing
        // entry is a catalog/selection drift bug (e.g. a catalog rename that
        // forgot to update this switch). Rather than crash every user on
        // that hardware/quality combo, log it as a fault and fall back to
        // the catalog's recommended model so transcription still works.
        if let info = ModelCatalog.info(for: id) {
            return info
        }
        modelSelectionLog.fault("ModelSelection: '\(id, privacy: .public)' is missing from ModelCatalog.all; falling back to recommended model")
        return ModelCatalog.recommended
    }

    /// Infers the quality tier an already-installed model id represents:
    /// any "large" variant is `.bestQuality`, everything else is `.faster`.
    public static func quality(inferredFrom modelID: String) -> TranscriptionQuality {
        modelID.contains("large") ? .bestQuality : .faster
    }

    public enum Plan: Equatable {
        /// The target model is already installed — just activate it (and
        /// clean up any other installed catalog models, which are no longer
        /// needed once the new quality is active).
        case ready(activate: String, deleteOthers: [String])
        /// The target model needs to be downloaded first; `thenDelete` lists
        /// other installed catalog models to remove once the download and
        /// activation complete.
        case download(ModelInfo, thenDelete: [String])
    }

    /// Plans the steps to move to `quality` on `hardware`, given what's
    /// currently installed (`installedIDs`) and active (`activeID`).
    /// `activeID` isn't consulted for branching today (installed-vs-not is
    /// the only distinction that matters) but is accepted so callers don't
    /// need to special-case "nothing active yet" themselves.
    public static func reconcile(
        quality: TranscriptionQuality,
        hardware: HardwareProfile,
        installedIDs: Set<String>,
        activeID: String?
    ) -> Plan {
        let target = model(for: quality, hardware: hardware)
        let otherInstalled = ModelCatalog.all
            .map(\.id)
            .filter { $0 != target.id && installedIDs.contains($0) }

        if installedIDs.contains(target.id) {
            return .ready(activate: target.id, deleteOthers: otherInstalled)
        }
        return .download(target, thenDelete: otherInstalled)
    }
}
