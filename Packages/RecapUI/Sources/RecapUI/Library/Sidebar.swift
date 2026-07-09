import RecapTranscription
import SwiftUI

public enum SidebarItem: String, CaseIterable, Identifiable {
    case library
    case models

    public var id: String { rawValue }

    var label: String {
        switch self {
        case .library: "Library"
        case .models: "Models"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "rectangle.stack"
        case .models: "arrow.down.circle"
        }
    }
}

struct Sidebar: View {
    private static let visibleItems: [SidebarItem] = [.library, .models]

    @Binding var selection: SidebarItem?
    @Environment(LibraryStore.self) private var library
    @Environment(WhisperModelManager.self) private var models
    @Environment(AppStores.self) private var stores

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(Self.visibleItems) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 12))
                            .foregroundStyle(selection == item ? Tokens.accentBlue : Tokens.textSecondary)
                            .frame(width: 16)
                        Text(item.label)
                            .font(.system(size: 13, weight: selection == item ? .semibold : .regular))
                        Spacer()
                        if item == .library, !library.meetings.isEmpty {
                            Text("\(library.meetings.count)")
                                .font(.system(size: 11))
                                .foregroundStyle(Tokens.textTertiary)
                                .monospacedDigit()
                        }
                    }
                    .tag(item)
                    .axID(item == .models ? .sidebarModels : nil)
                }
            }
            .listStyle(.sidebar)
            .axID(.sidebar)
            // Design global #2: sidebar selection should read as a neutral
            // translucent fill, not accent blue. `.tint()` was tried here
            // first, but on macOS `List`'s tint bridges to the *window's*
            // control tint rather than staying scoped to this view subtree —
            // it silently recolored unrelated blue progress bars elsewhere
            // in the window. Left as native accent-blue selection instead;
            // a fully neutral selection would need a custom
            // NSTableView-level row-color override, which is a bigger change
            // than this pass's budget.

            if let queue = library.queueSummary {
                QueueWidget(summary: queue)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            if stores.updateStatus.isAvailable {
                UpdateChip { stores.updateStatus.triggerInstall() }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            activeModelFooter
        }
    }

    private var activeModelFooter: some View {
        Button {
            selection = .models
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(models.activeModel == nil ? Color.orange : Tokens.successGreen)
                    .frame(width: 6, height: 6)
                Text(models.activeModel.map { "\($0.displayName) · \($0.languages)" } ?? "No model installed")
                    .font(Tokens.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

/// Sidebar footer card: a new version is ready. Clicking presents Sparkle's
/// standard update dialog (release notes + Install).
struct UpdateChip: View {
    var onInstall: () -> Void

    var body: some View {
        Button(action: onInstall) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.accentBlue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Tokens.textPrimary)
                    Text("Click to install")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Tokens.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.accentBlue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

/// Sidebar footer card: aggregate progress of the background processing
/// queue (design mock 6a). No pause affordance — `ProcessingQueue` has no
/// pause API today (only an automatic battery-triggered pause reflected in
/// `pauseReason`), so we show status only rather than inventing a control
/// that wouldn't do anything.
struct QueueWidget: View {
    var summary: QueueSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Processing queue")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("\(summary.jobCount) recording\(summary.jobCount == 1 ? "" : "s") · \(Int((summary.progress * 100).rounded()))%")
                .font(.system(size: 11))
                .foregroundStyle(Tokens.textSecondary)
            ProgressView(value: summary.progress)
                .tint(Tokens.accentBlue)
                .controlSize(.mini)
                .padding(.top, 6)
            Text(summary.pauseReason ?? "Low priority · pauses on battery")
                .font(.system(size: 10))
                .foregroundStyle(summary.pauseReason == nil ? Tokens.textTertiary : .orange)
                .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chipBackground, in: RoundedRectangle(cornerRadius: 9))
        .axID(.queueWidget)
    }
}
