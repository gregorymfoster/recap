import RecapTranscription
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case library
    case models
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: "Library"
        case .models: "Models"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .library: "rectangle.stack"
        case .models: "arrow.down.circle"
        case .settings: "gearshape"
        }
    }
}

struct Sidebar: View {
    @Binding var selection: SidebarItem?
    @Environment(LibraryStore.self) private var library
    @Environment(WhisperModelManager.self) private var models

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(item.label, systemImage: item.systemImage)
                        .badge(item == .library ? library.meetings.count : 0)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)

            if let queue = library.queueSummary {
                QueueWidget(summary: queue)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            activeModelFooter
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                RecapLogo()
                Text("Recap")
                    .font(.system(size: 14, weight: .bold))
                    .kerning(-0.2)
                    .foregroundStyle(Tokens.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
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

/// Sidebar footer card: aggregate progress of the background processing queue.
struct QueueWidget: View {
    var summary: QueueSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Processing queue")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Tokens.textPrimary)
            Text("\(summary.jobCount) recording\(summary.jobCount == 1 ? "" : "s") · low priority")
                .font(.system(size: 10.5))
                .foregroundStyle(Tokens.textSecondary)
            Text("pauses on battery")
                .font(.system(size: 10.5))
                .foregroundStyle(Tokens.textSecondary)
            ProgressView(value: summary.progress)
                .tint(Tokens.accentBlue)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}
