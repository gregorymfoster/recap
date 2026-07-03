import Foundation
import RecapTranscription
import SwiftUI

/// The Models section: download, activate, and delete Whisper variants.
struct ModelManagerView: View {
    @Environment(WhisperModelManager.self) private var manager
    @State private var freeDiskBytes: Int64?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Models")
                    .font(Tokens.sectionTitle)
                    .foregroundStyle(Tokens.textPrimary)
                    .kerning(-0.3)
                Text("Speech models run entirely on this Mac. Downloaded once from Hugging Face, then everything works offline.")
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(.top, 4)
                    .padding(.bottom, 20)

                LazyVStack(spacing: 10) {
                    ForEach(ModelCatalog.all) { model in
                        ModelRow(model: model, state: manager.states[model.id] ?? .available, freeDiskBytes: freeDiskBytes)
                    }
                }
            }
            .padding(28)
        }
        .background(Tokens.surface)
        .onAppear {
            manager.refresh()
            freeDiskBytes = Self.availableDiskBytes(for: WhisperModelManager.defaultModelsRoot)
        }
    }

    /// Free space on the volume that holds the models folder, using the
    /// "important usage" key so it accounts for space macOS could reclaim
    /// from purgeable caches — the same number System Settings' Storage pane
    /// effectively bases its own headroom on.
    private static func availableDiskBytes(for url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap(\.volumeAvailableCapacityForImportantUsage)
    }
}

private struct ModelRow: View {
    var model: ModelInfo
    var state: ModelState
    var freeDiskBytes: Int64?
    @Environment(WhisperModelManager.self) private var manager

    private var isActive: Bool { manager.activeModelID == model.id }
    private var diskSpaceFootnote: String? {
        guard case .available = state else { return nil }
        return ModelDiskSpace.footnote(freeBytes: freeDiskBytes, modelSizeMB: model.approximateSizeMB, modelDisplayName: model.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.displayName)
                            .font(Tokens.rowTitle)
                            .foregroundStyle(Tokens.textPrimary)
                        if model.isRecommended {
                            chip("Recommended", foreground: Tokens.accentBlue, background: Tokens.accentBlue.opacity(0.1))
                        }
                        if isActive {
                            chip("Active", foreground: Tokens.successGreenText, background: Tokens.successGreenTint)
                        } else if state == .installed {
                            chip("Installed", foreground: Tokens.textSecondary, background: Tokens.chipBackground)
                        }
                    }
                    Text("\(model.languages) · ~\(model.approximateSizeMB) MB · \(model.qualityHint)")
                        .font(Tokens.meta)
                        .foregroundStyle(Tokens.textSecondary)
                }
                Spacer(minLength: 12)
                actions
            }
            if let diskSpaceFootnote {
                Text(diskSpaceFootnote)
                    .font(Tokens.caption)
                    .foregroundStyle(Tokens.warningAmberText)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .fill(Tokens.surface)
                .stroke(Tokens.cardStroke, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .available:
            Button("Download") { manager.download(model) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .downloading(let progress):
            HStack(spacing: 10) {
                ProgressView(value: max(0.02, progress))
                    .tint(Tokens.accentBlue)
                    .frame(width: 140)
                Text("\(Int(progress * 100))%")
                    .font(Tokens.caption.monospacedDigit())
                    .foregroundStyle(Tokens.textSecondary)
                Button("Pause") { manager.pauseDownload(of: model) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        case .installed:
            HStack(spacing: 8) {
                if !isActive {
                    Button("Use") { manager.setActive(model.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Delete", role: .destructive) { manager.delete(model) }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
    }

    private func chip(_ label: String, foreground: Color, background: Color) -> some View {
        Text(label)
            .font(Tokens.microLabel)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: Tokens.radiusChip))
    }
}
