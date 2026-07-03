import RecapCore
import RecapTranscription
import SwiftUI
import UniformTypeIdentifiers

/// The Library home screen (design mock 1c): header with Record button,
/// meeting cards with processing status, summary preview for the latest
/// enhanced meeting.
struct LibraryView: View {
    @Environment(AppStores.self) private var stores: AppStores?
    @Environment(LibraryStore.self) private var library
    @Environment(MeetingSessionStore.self) private var session
    @Environment(WhisperModelManager.self) private var models
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router

    @State private var dropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 20)
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                if library.meetings.isEmpty {
                    emptyState
                        .padding(.horizontal, 28)
                } else if library.displayMeetings.isEmpty {
                    filteredEmptyState
                        .padding(.horizontal, 28)
                } else {
                    content
                        .padding(.horizontal, 28)
                }
                Color.clear.frame(height: 28)
            }
        }
        .background(Tokens.surface)
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls)
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropHighlight } }
    }

    /// Files dragged from Finder: audio-conforming ones import; anything
    /// else gets a toast instead of silently vanishing.
    private func handleDrop(_ urls: [URL]) -> Bool {
        let audio = urls.filter {
            UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audio) == true
        }
        for url in urls where !audio.contains(url) {
            stores?.toasts.show("Couldn't import \(url.lastPathComponent) — not an audio file")
        }
        guard !audio.isEmpty else { return false }
        stores?.importAudioFiles(audio)
        return true
    }

    private var dropHighlight: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .fill(Tokens.accentBlue.opacity(0.06))
                .stroke(Tokens.accentBlue, lineWidth: 2)
            Label("Drop audio to import", systemImage: "square.and.arrow.down")
                .font(Tokens.rowTitle)
                .foregroundStyle(Tokens.accentBlue)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Tokens.surface, in: Capsule())
                // stays: shadow stays black in both modes (drop shadows read fine on dark surfaces)
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .padding(10)
        .allowsHitTesting(false)
    }

    /// Grouped-with-headers for date sorts, a flat list for `.longest` (a
    /// duration ranking reads oddly split into date buckets).
    @ViewBuilder private var content: some View {
        if library.sort == .longest {
            LazyVStack(spacing: 10) {
                ForEach(library.displayMeetings) { record in
                    row(for: record)
                }
            }
        } else {
            let sections = MeetingGrouping.sections(library.displayMeetings, now: .now, calendar: .current)
            LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.id) { section in
                    Section {
                        ForEach(section.records) { record in
                            row(for: record)
                        }
                    } header: {
                        sectionHeader(section.title)
                    }
                }
            }
        }
    }

    private func row(for record: MeetingRecord) -> some View {
        MeetingRow(record: record) { router.section = .models }
            .onTapGesture { library.selectedMeetingID = record.meeting.id }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Tokens.microLabel)
            .foregroundStyle(Tokens.textTertiary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Opaque background so pinned headers don't show rows scrolling
            // underneath them.
            .background(Tokens.surface)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No meetings yet", systemImage: "waveform")
                .font(Tokens.rowTitle)
                .foregroundStyle(Tokens.textPrimary)
        } description: {
            Text("Hit Record when your next call starts. Recap captures the audio, transcribes it on this Mac, and turns your rough notes into a clean summary.")
                .font(Tokens.meta)
                .foregroundStyle(Tokens.textSecondary)
        }
        .padding(.top, 120)
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("No matching meetings", systemImage: "line.3.horizontal.decrease.circle")
                .font(Tokens.rowTitle)
                .foregroundStyle(Tokens.textPrimary)
        } description: {
            Text("Try loosening the filter — fewer conditions or a shorter minimum length.")
                .font(Tokens.meta)
                .foregroundStyle(Tokens.textSecondary)
        }
        .padding(.top, 120)
    }

    private var header: some View {
        HStack {
            Text("Library")
                .font(Tokens.sectionTitle)
                .foregroundStyle(Tokens.textPrimary)
                .kerning(-0.3)
            Spacer()
            if !library.meetings.isEmpty {
                sortFilterMenu
            }
            Button {
                stores?.startRecording()
            } label: {
                HStack(spacing: 7) {
                    // stays: white dot/text on the red Record button in both modes
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text("Record")
                        .font(.system(size: 13, weight: .semibold))
                }
                // stays: white text on the red Record button in both modes
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Tokens.recordRed, in: RoundedRectangle(cornerRadius: Tokens.radiusButton))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var sortFilterMenu: some View {
        @Bindable var library = library
        return Menu {
            Picker("Sort", selection: $library.sort) {
                ForEach(LibrarySort.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            Divider()
            Toggle("Ready only", isOn: $library.filter.readyOnly)
            Toggle("Longer than 15 minutes", isOn: Binding(
                get: { library.filter.minDuration != nil },
                set: { library.filter.minDuration = $0 ? 900 : nil }
            ))
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Tokens.textSecondary)
                    .padding(6)
                if library.filter.isActive {
                    Circle()
                        .fill(Tokens.accentBlue)
                        .frame(width: 6, height: 6)
                        .offset(x: -2, y: 2)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Sort and filter the library")
    }
}

private struct MeetingRow: View {
    var record: MeetingRecord
    var onInstallModel: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            iconTile
            VStack(alignment: .leading, spacing: 2) {
                Text(record.meeting.title)
                    .font(Tokens.rowTitle)
                    .foregroundStyle(Tokens.textPrimary)
                    .lineLimit(1)
                Text(record.meeting.metaLine)
                    .font(Tokens.meta)
                    .foregroundStyle(Tokens.textSecondary)
            }
            Spacer(minLength: 12)
            MeetingStatusView(status: record.meeting.status, onInstallModel: onInstallModel)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Tokens.radiusCard)
                .fill(hovering ? Tokens.subtleBackground : Tokens.surface)
                .stroke(Tokens.cardStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: Tokens.radiusCard))
        .onHover { hovering = $0 }
    }

    private var iconTile: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(tint.opacity(0.12))
            .frame(width: 36, height: 36)
            .overlay {
                Image(systemName: record.meeting.attendees.count > 1 ? "person.2.fill" : "waveform")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
            }
    }

    private var tint: Color {
        // stays: flat accent palette (icon-tile fill), same as accentBlue/successGreen — not appearance-dependent
        let palette: [Color] = [Tokens.accentBlue, Color(red: 0x8E / 255, green: 0x7C / 255, blue: 0xC3 / 255), Tokens.successGreen, .orange]
        return palette[abs(record.meeting.id.hashValue) % palette.count]
    }
}

#Preview {
    LibraryView()
        .environment(LibraryStore.fixture())
        .environment(AppRouter())
        .frame(width: 820, height: 620)
}

#Preview("Dark") {
    LibraryView()
        .environment(LibraryStore.fixture())
        .environment(AppRouter())
        .frame(width: 820, height: 620)
        .preferredColorScheme(.dark)
}
