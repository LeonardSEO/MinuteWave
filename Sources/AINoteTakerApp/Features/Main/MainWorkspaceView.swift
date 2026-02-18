import SwiftUI
import AppKit

struct MainWorkspaceView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: AppViewModel

    @State private var search: String = ""
    @State private var chatInput: String = ""
    @State private var exportedURL: URL?
    @State private var showSettings = false
    @State private var showNewSessionSheet = false
    @State private var draftSessionNameInput = ""
    @State private var isRenamingSession = false
    @State private var renameSessionInput = ""
    @State private var isTranscriptCollapsed = false

    private var hasTranscript: Bool {
        viewModel.currentSegments.contains(where: { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    private var isRecordingLike: Bool {
        viewModel.activeSessionStatus == .recording || viewModel.activeSessionStatus == .finalizing
    }

    private var shouldHideLiveText: Bool {
        isRecordingLike && !viewModel.settings.transcriptionConfig.realtimeEnabled
    }

    private var visibleSegments: [TranscriptSegment] {
        if shouldHideLiveText {
            return viewModel.currentSegments.filter(\.isFinal)
        }
        return viewModel.currentSegments
    }

    private var visibleTranscriptText: String {
        Self.mergeTranscriptText(from: visibleSegments)
    }

    private var captureModeText: String {
        viewModel.settings.transcriptionConfig.audioCaptureMode.localizedShortLabel
    }

    private var workspaceSurfaceColor: Color {
        if colorScheme == .dark {
            return Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
        }
        return Color.white
    }

    private var workspaceInnerSheen: Color {
        colorScheme == .dark ? Color.white.opacity(0.01) : Color.clear
    }

    private var workspaceDividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.05)
    }

    private var workspaceBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.06)
    }

    private var workspaceShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: RectangleCornerRadii(topLeading: 16, bottomLeading: 16, bottomTrailing: 0, topTrailing: 0),
            style: .continuous
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            SidebarLiquidGlassView()
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.035 : 0.10),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .ignoresSafeArea()

            GeometryReader { proxy in
                let totalWidth = proxy.size.width
                let sidebarWidth = min(max(totalWidth * 0.18, 260), 310)
                let workspaceWidth = max(640, totalWidth - sidebarWidth)
                let contentWidth = min(max(workspaceWidth * 0.43, 400), 620)
                let sidebarTopInset = max(36, proxy.safeAreaInsets.top + 4)

                HStack(spacing: 0) {
                    sidebar(topInset: sidebarTopInset)
                        .frame(width: sidebarWidth)
                        .overlay(alignment: .trailing) {
                            Rectangle()
                                .fill(workspaceDividerColor)
                                .frame(width: 1)
                                .padding(.vertical, 14)
                        }

                    HStack(spacing: 0) {
                        contentPanel
                            .frame(width: contentWidth, alignment: .topLeading)

                        Rectangle()
                            .fill(workspaceDividerColor)
                            .frame(width: 1)

                        detailPanel
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .background {
                        workspaceShape
                        .fill(workspaceSurfaceColor)
                        .overlay(
                            workspaceShape
                            .fill(workspaceInnerSheen)
                        )
                        .overlay(
                            workspaceShape
                                .strokeBorder(workspaceBorderColor, lineWidth: 1)
                        )
                    }
                    .clipShape(workspaceShape)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(edges: .top)
            }

            LocalPreparationOverlay(state: viewModel.startupPreparation)
        }
        .background(ScrollChromeConfigurator(colorScheme: colorScheme))
        .onAppear {
            isTranscriptCollapsed = viewModel.settings.transcriptDefaultCollapsed
        }
        .onChange(of: search) { _, newValue in
            Task { await viewModel.refreshSessions(search: newValue) }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
                .frame(minWidth: 720, minHeight: 620)
        }
        .sheet(isPresented: $showNewSessionSheet) {
            newSessionSheet
        }
        .onChange(of: viewModel.selectedSessionId) { _, _ in
            isRenamingSession = false
            isTranscriptCollapsed = viewModel.settings.transcriptDefaultCollapsed
        }
        .onChange(of: viewModel.settings.transcriptDefaultCollapsed) { _, value in
            isTranscriptCollapsed = value
        }
    }

    private func sidebar(topInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                draftSessionNameInput = defaultSessionName()
                showNewSessionSheet = true
            } label: {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: "plus")
                    Text(L10n.tr("ui.main.new_session"))
                    Spacer(minLength: 0)
                }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 32)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.accentColor.opacity(colorScheme == .dark ? 0.92 : 0.84),
                                        Color.accentColor.opacity(colorScheme == .dark ? 0.64 : 0.58),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.28 : 0.34), lineWidth: 1)
                    )
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .medium))

                NativeTextField(
                    placeholder: L10n.tr("ui.main.search_sessions"),
                    text: $search,
                    isBorderless: true
                )
                .frame(height: 20)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        colorScheme == .dark
                        ? Color.white.opacity(0.15)
                        : Color.black.opacity(0.12),
                        lineWidth: 1
                    )
            )

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.sessions) { session in
                        Button {
                            Task { await viewModel.selectSession(session.id) }
                        } label: {
                            sessionRow(session)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 8)

            Button {
                showSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                    Text(L10n.tr("ui.common.settings"))
                    Spacer(minLength: 0)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 10)
        .padding(.top, topInset)
        .padding(.bottom, 10)
    }

    private var contentPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if isRenamingSession, let selected = selectedSession {
                    NativeTextField(
                        placeholder: L10n.tr("ui.main.session_name"),
                        text: $renameSessionInput,
                        onSubmit: { commitRename(selected.id) }
                    )
                    .frame(height: 30)

                    Button(L10n.tr("ui.common.save")) {
                        commitRename(selected.id)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                Text(currentSessionName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)

                    Button {
                        startRename()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }

                Spacer()
            }

            statusStrip
            liveWaveformBar

            HStack {
                Text(L10n.tr("ui.main.transcript"))
                    .font(.headline)
                Spacer()
                Button(isTranscriptCollapsed ? L10n.tr("ui.main.expand") : L10n.tr("ui.main.collapse")) {
                    isTranscriptCollapsed.toggle()
                }
                .buttonStyle(.bordered)
            }

            if isTranscriptCollapsed {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("ui.main.transcript_collapsed"))
                        .foregroundStyle(.secondary)
                    Button(L10n.tr("ui.main.show_full_transcript")) {
                        isTranscriptCollapsed = false
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassCard()
            } else if viewModel.activeSessionStatus == .finalizing {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(L10n.tr("ui.main.transcript_processing"))
                            .foregroundStyle(.secondary)
                    }
                    Text(L10n.tr("ui.main.transcript_processing_detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassCard()
            } else {
                ScrollView {
                    if visibleTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(L10n.tr("ui.main.no_transcript_yet"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .liquidGlassCard()
                    } else {
                        Text(visibleTranscriptText)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .liquidGlassCard()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusChip(
                    text: viewModel.activeSessionStatus.localizedLabel,
                    color: statusColor,
                    systemImage: "dot.radiowaves.left.and.right"
                )

                statusChip(
                    text: L10n.tr("ui.main.transcription_status_chip", viewModel.localTranscriptionStatusText),
                    color: viewModel.isLocalTranscriptionHealthy ? .green : .secondary,
                    systemImage: "waveform.and.mic"
                )

                Menu {
                    Button(LocalAudioCaptureMode.microphoneOnly.localizedLabel) {
                        Task { await viewModel.updateAudioCaptureMode(.microphoneOnly) }
                    }
                    Button(LocalAudioCaptureMode.microphoneAndSystem.localizedLabel) {
                        Task { await viewModel.updateAudioCaptureMode(.microphoneAndSystem) }
                    }
                } label: {
                    statusChip(
                        text: captureModeText,
                        color: .secondary,
                        systemImage: "mic"
                    )
                }
                .menuStyle(.borderlessButton)
            }

            if let warning = viewModel.localCaptureWarningText, !warning.isEmpty {
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            if viewModel.isRecordingTemporarilyBlocked {
                Text(viewModel.startupPreparation.statusDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(viewModel.localCaptureStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var liveWaveformBar: some View {
        HStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(viewModel.liveWaveformSamples.enumerated()), id: \.offset) { _, sample in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white.opacity(0.95))
                        .frame(width: 3, height: max(8, 46 * sample))
                        .animation(.linear(duration: 0.08), value: sample)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(viewModel.recordingElapsedLabel)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            recorderButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var recorderButton: some View {
        if viewModel.activeSessionStatus == .finalizing {
            ProgressView()
                .frame(width: 38, height: 38)
        } else {
            Button {
                toggleRecording()
            } label: {
                Image(systemName: isRecordingLike ? "stop.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Circle().fill(isRecordingLike ? Color.red : Color.blue)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!(viewModel.canStartRecording || viewModel.canStopRecording))
        }
    }

    private func toggleRecording() {
        if viewModel.canStopRecording {
            Task { await viewModel.stopRecording() }
            return
        }

        guard viewModel.canStartRecording else { return }
        let trimmed = viewModel.recordingSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = trimmed.isEmpty ? defaultSessionName() : trimmed
        viewModel.recordingSessionName = sessionName
        Task { await viewModel.startRecording(with: sessionName) }
    }

    private var newSessionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("ui.main.new_session"))
                .font(.title3.weight(.semibold))

            NativeTextField(
                placeholder: L10n.tr("ui.main.session_name"),
                text: $draftSessionNameInput,
                onSubmit: { createDraftSession() }
            )
            .frame(height: 30)

            HStack {
                Spacer()
                Button(L10n.tr("ui.common.cancel")) {
                    showNewSessionSheet = false
                }
                Button(L10n.tr("ui.common.continue")) {
                    createDraftSession()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func createDraftSession() {
        let trimmed = draftSessionNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? defaultSessionName() : trimmed
        viewModel.prepareNewSessionDraft()
        viewModel.recordingSessionName = name
        showNewSessionSheet = false
    }

    private func startRename() {
        guard let selected = selectedSession else { return }
        renameSessionInput = selected.name
        isRenamingSession = true
    }

    private func commitRename(_ sessionId: UUID) {
        let trimmed = renameSessionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            isRenamingSession = false
            return
        }
        isRenamingSession = false
        Task { await viewModel.renameSession(sessionId, to: trimmed) }
    }

    private func statusChip(text: String, color: Color, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }

    private var detailPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sessionDetailsCard
            summaryCard

            HStack {
                Text(L10n.tr("ui.main.chat_with_transcript"))
                    .font(.headline)
                Spacer()
                if hasTranscript {
                    Button(L10n.tr("ui.main.summarize")) {
                        Task { await viewModel.generateSummaryIfAvailable() }
                    }
                    .buttonStyle(.bordered)

                    Menu(L10n.tr("ui.main.export")) {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.rawValue.uppercased()) {
                                Task {
                                    exportedURL = await viewModel.exportSelectedSession(as: format)
                                }
                            }
                        }
                    }
                }
            }

            if hasTranscript {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.currentChatMessages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role.localizedLabel)
                                    .font(.caption.bold())
                                    .foregroundStyle(message.role == .assistant ? .mint : .secondary)
                                Text(message.text)
                                if !message.citations.isEmpty {
                                    Text(message.citations.map { "[\($0.startMs)-\($0.endMs)]" }.joined(separator: ", "))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .liquidGlassCard()
                        }
                    }
                }

                HStack(spacing: 10) {
                    NativeTextField(
                        placeholder: L10n.tr("ui.main.chat_placeholder"),
                        text: $chatInput,
                        isBorderless: true,
                        onSubmit: { sendChatPrompt() }
                    )
                    .frame(height: 22)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: Capsule())

                    Button {
                        sendChatPrompt()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                    .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

                if let url = exportedURL {
                    Text(L10n.tr("ui.main.exported_file", url.lastPathComponent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.tr("ui.main.chat_export_hint"))
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("ui.main.chat_export_tip"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlassCard()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
    }

private func sendChatPrompt() {
    let prompt = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return }
    chatInput = ""
    Task { await viewModel.sendChat(question: prompt) }
}

private var selectedSession: SessionRecord? {
    guard let id = viewModel.selectedSessionId else { return nil }
    return viewModel.sessions.first(where: { $0.id == id })
}

private var currentSessionName: String {
    if let session = selectedSession {
        return session.name
    }
    let draft = viewModel.recordingSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
    return draft.isEmpty ? L10n.tr("ui.main.new_session") : draft
}

private func defaultSessionName() -> String {
    L10n.tr("ui.main.session.default_name", Date().formatted(date: .abbreviated, time: .shortened))
}

private func sessionRow(_ session: SessionRecord) -> some View {
    let isSelected = viewModel.selectedSessionId == session.id
    let fillColor: Color = {
        if isSelected {
            return colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
        }
        return .clear
    }()

    return VStack(alignment: .leading, spacing: 4) {
        Text(session.name)
            .font(.headline)
            .lineLimit(1)
        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(fillColor)
    )
    .contentShape(Rectangle())
}

private static func mergeTranscriptText(from segments: [TranscriptSegment]) -> String {
    segments
        .sorted { $0.startMs < $1.startMs }
        .map { segment in
            let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { return "" }
            if let speaker = segment.speakerLabel, !speaker.isEmpty {
                return "\(speaker): \(trimmedText)"
            }
            return trimmedText
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
}

private var sessionDetailsCard: some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(L10n.tr("ui.main.session_details"))
            .font(.headline)

        if let session = selectedSession {
            Text(L10n.tr("ui.main.session_details.name", session.name))
            Text(L10n.tr("ui.main.session_details.provider", session.transcriptionProvider.localizedLabel))
            Text(L10n.tr("ui.main.session_details.start", session.startedAt.formatted(date: .abbreviated, time: .shortened)))
            Text(L10n.tr("ui.main.session_details.status", session.status.localizedLabel))
        } else {
            Text(L10n.tr("ui.main.no_session_selected"))
                .foregroundStyle(.secondary)
        }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .liquidGlassCard()
}

private var summaryCard: some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(L10n.tr("ui.main.summary"))
            .font(.headline)
        ScrollView {
            MarkdownSummaryView(source: viewModel.currentSummary?.executiveSummary ?? L10n.tr("ui.main.no_summary_yet"))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 110, maxHeight: 250)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .liquidGlassCard()
}

private var statusColor: Color {
    switch viewModel.activeSessionStatus {
    case .recording: return .red
    case .paused: return .orange
    case .finalizing: return .yellow
    case .completed: return .green
    case .failed: return .pink
    case .idle: return .secondary
    }
}

}

private struct SidebarLiquidGlassView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}
