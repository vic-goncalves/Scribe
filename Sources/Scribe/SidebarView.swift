import SwiftUI

struct SidebarView: View {
    let onImport: () -> Void

    @Environment(Library.self) private var library
    @Environment(Transcriber.self) private var transcriber
    @Environment(AppState.self) private var appState
    @State private var hits: [SearchHit] = []
    @FocusState private var listFocused: Bool

    private var isSearching: Bool { !appState.searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 2) {
            // Sits on the same line as the window's close/minimize/zoom buttons.
            HStack {
                Spacer()
                AppearanceButton()
            }
            .frame(height: 32)
            .padding(.top, 1)

            SearchField(text: $appState.searchText, prompt: "Search transcripts")
                .padding(.top, 11)
                .padding(.bottom, 4)

            SidebarRow(icon: "plus", title: "New transcript", shortcut: "⌘N", action: onImport)
                .help("Import audio files. You can also drop files anywhere in the window.")

            if isSearching {
                searchResults
            } else {
                recordingList
            }

            ModelSwitcherButton()
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .background(Theme.sidebar)
        .task(id: appState.searchText) {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            hits = library.search(appState.searchText)
        }
    }

    // MARK: Recordings

    private var recordingList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(DateSection.group(library.recordings), id: \.title) { section in
                        SectionLabel(title: section.title)
                        ForEach(section.recordings) { recording in
                            RecordingRow(
                                recording: recording,
                                isSelected: appState.selection == recording.id,
                                progress: transcriber.activeRecordingId == recording.id ? transcriber.activeProgress : nil
                            ) {
                                appState.selection = recording.id
                                listFocused = true
                            }
                            .id(recording.id)
                            .contextMenu { menu(for: recording) }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) {
                appState.selectAdjacent(1, in: library.recordings)
                return .handled
            }
            .onKeyPress(.upArrow) {
                appState.selectAdjacent(-1, in: library.recordings)
                return .handled
            }
            .onChange(of: appState.selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            .defaultFocus($listFocused, true)
            .onAppear { listFocused = true }
        }
    }

    @ViewBuilder
    private func menu(for recording: Recording) -> some View {
        if let id = recording.id {
            Button("Rename") {
                appState.selection = id
                appState.renameRequest = id
            }
            Button("Show Audio in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.audioURL(for: recording)])
            }
            if recording.status == .done || recording.status == .failed {
                Button("Transcribe Again") {
                    library.requeue(id)
                    transcriber.processQueue()
                }
            }
            Divider()
            Button("Delete…", role: .destructive) { appState.pendingDeletion = id }
        }
    }

    // MARK: Search

    private var searchResults: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                SectionLabel(title: hits.isEmpty ? "No matches" : "\(hits.count) \(hits.count == 1 ? "match" : "matches")")
                ForEach(groupedHits, id: \.recordingId) { group in
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.tertiaryText)
                        Text(group.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
                    ForEach(group.hits) { hit in
                        SearchHitRow(hit: hit, query: appState.searchText) {
                            appState.selection = hit.segment.recordingId
                            appState.seekRequest = SeekRequest(recordingId: hit.segment.recordingId, time: hit.segment.start, segmentId: hit.segment.id)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    /// Groups hits by recording, ordering recordings by their best-scoring hit.
    private var groupedHits: [(recordingId: Int64, title: String, hits: [SearchHit])] {
        var order: [Int64] = []
        var byRecording: [Int64: [SearchHit]] = [:]
        for hit in hits {
            let id = hit.segment.recordingId
            if byRecording[id] == nil { order.append(id) }
            byRecording[id, default: []].append(hit)
        }
        return order.map { id in
            let group = byRecording[id]!.sorted { $0.segment.start < $1.segment.start }
            return (id, group[0].recordingTitle, group)
        }
    }
}

struct DateSection {
    let title: String
    let recordings: [Recording]

    /// Buckets recordings (already newest first) into Today, Yesterday, Previous 7 Days, then by month.
    static func group(_ recordings: [Recording], now: Date = .now, calendar: Calendar = .current) -> [DateSection] {
        var sections: [DateSection] = []
        for recording in recordings {
            let title = sectionTitle(for: recording.createdAt, now: now, calendar: calendar)
            if sections.last?.title == title {
                sections[sections.count - 1] = DateSection(title: title, recordings: sections[sections.count - 1].recordings + [recording])
            } else {
                sections.append(DateSection(title: title, recordings: [recording]))
            }
        }
        return sections
    }

    static func sectionTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)), date >= weekAgo {
            return "Previous 7 Days"
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.wide))
        }
        return date.formatted(.dateTime.month(.wide).year())
    }
}

/// A single-line sidebar item: icon, title, optional trailing hint.
private struct SidebarRow: View {
    let icon: String
    let title: String
    var shortcut: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                if let shortcut, isHovered {
                    Text(shortcut)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }
}

private struct RecordingRow: View {
    let recording: Recording
    let isSelected: Bool
    let progress: Double?
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 16)
                Text(recording.title)
                    .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(trailing)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Theme.selection : isHovered ? Theme.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(recording.title)\n\(recording.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(formatDuration(recording.duration))")
    }

    private var trailing: String {
        switch recording.status {
        case .queued: "Queued"
        case .transcribing: (progress ?? 0) > 0 ? "\(Int((progress ?? 0) * 100))%" : "Working"
        case .failed: "Failed"
        case .done: formatTimestamp(recording.duration)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch recording.status {
        case .done:
            Image(systemName: "waveform")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
        case .transcribing:
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.8)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit
    let query: String
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(formatTimestamp(hit.segment.start))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryText)
                    .frame(width: 34, alignment: .trailing)
                Text(highlighted)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    /// Marks each query word wherever it appears verbatim (fuzzy-only matches stay unmarked).
    private var highlighted: AttributedString {
        var text = AttributedString(hit.segment.text)
        let words = query.split(separator: " ").map(String.init).filter { $0.count >= 2 }
        for word in words {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text[searchRange].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].foregroundColor = Theme.text
                text[range].backgroundColor = Theme.highlight
                searchRange = range.upperBound..<text.endIndex
            }
        }
        return text
    }
}

private struct AppearanceButton: View {
    @AppStorage(AppearanceMode.storageKey) private var appearance = AppearanceMode.system

    var body: some View {
        Menu {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: appearance.icon)
        }
        .menuStyle(.button)
        .buttonStyle(IconButtonStyle(size: 26))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance: \(appearance.label)")
    }
}

private struct ModelSwitcherButton: View {
    @Environment(Transcriber.self) private var transcriber
    @Environment(AppState.self) private var appState
    @State private var isHovered = false

    var body: some View {
        Button { appState.showModelPicker = true } label: {
            HStack(spacing: 8) {
                statusDot
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(transcriber.currentModel.map { "\($0.name) model" } ?? "No model")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiaryText)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.tertiaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isHovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Switch or download speech models")
    }

    private var statusText: String {
        switch transcriber.phase {
        case .loading: "Loading…"
        case .failed: "Unavailable. Click to fix."
        default: transcriber.speakersUnavailable ? "Speaker detection unavailable" : "On-device · Private"
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch transcriber.phase {
        case .loading:
            ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .failed:
            Circle().fill(.orange).frame(width: 7, height: 7)
        default:
            Circle().fill(Color.green).frame(width: 7, height: 7)
        }
    }
}
