import SwiftUI

struct MiniRecorderStackView: View {
    @ObservedObject var engine: VoiceInkEngine
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onCancelTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    let onCancelSession: (UUID) -> Void

    private let cardSpacing: CGFloat = 46
    private var ordered: [RecordingSession] { engine.sessions }
    private var activeSession: RecordingSession? { engine.activeRecordingSession }
    private var backgroundSessions: [RecordingSession] {
        ordered.filter { session in
            guard session.id != activeSession?.id else { return false }
            switch session.phase {
            case .queued, .transcribing, .delivering: return true
            case .recording, .done: return false
            }
        }
    }

    private var visibleSessions: [RecordingSession] {
        ordered.filter { session in
            session.id == activeSession?.id || backgroundSessions.contains(where: { $0.id == session.id })
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(visibleSessions) { session in
                cardView(for: session)
                    .offset(y: -cardSpacing * CGFloat(indexFromBottom(of: session)))
                    .zIndex(zIndex(for: session))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if ordered.isEmpty && assistantSession.isVisible {
                MiniRecorderView(
                    stateProvider: engine, recorder: recorder, assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped, onCloseTapped: onCloseTapped,
                    onCancelTapped: onCancelTapped, onAssistantFollowUp: onAssistantFollowUp
                )
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: engine.sessions.map(\.id))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func indexFromBottom(of session: RecordingSession) -> Int {
        guard let idx = ordered.firstIndex(where: { $0.id == session.id }) else { return 0 }
        // Keep the active recording at the base. Without one, all cards are chips and
        // retain creation order rather than inventing a false full recorder.
        if let active = activeSession, let base = ordered.firstIndex(where: { $0.id == active.id }) {
            return max(0, base - idx)
        }
        return max(0, ordered.count - 1 - idx)
    }

    private func zIndex(for session: RecordingSession) -> Double {
        Double(ordered.count - indexFromBottom(of: session))
    }

    @ViewBuilder
    private func cardView(for session: RecordingSession) -> some View {
        if session.id == activeSession?.id {
            MiniRecorderView(
                stateProvider: session, recorder: recorder, assistantSession: assistantSession,
                onRecordButtonTapped: onRecordButtonTapped, onCloseTapped: onCloseTapped,
                onCancelTapped: onCancelTapped, onAssistantFollowUp: onAssistantFollowUp
            )
        } else {
            TranscribingChip(session: session, style: .mini, onCancel: { onCancelSession(session.id) })
        }
    }
}

struct NotchRecorderStackView: View {
    @ObservedObject var engine: VoiceInkEngine
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onCancelTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    let onCancelSession: (UUID) -> Void

    private var ordered: [RecordingSession] { engine.sessions }
    private var activeSession: RecordingSession? { engine.activeRecordingSession }
    private var backgroundSessions: [RecordingSession] {
        ordered.filter { session in
            guard session.id != activeSession?.id else { return false }
            switch session.phase {
            case .queued, .transcribing, .delivering: return true
            case .recording, .done: return false
            }
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 6) {
                if let activeSession {
                    NotchRecorderView(stateProvider: activeSession, recorder: recorder, assistantSession: assistantSession,
                        onRecordButtonTapped: onRecordButtonTapped, onCloseTapped: onCloseTapped,
                        onCancelTapped: onCancelTapped, onAssistantFollowUp: onAssistantFollowUp)
                }
                ForEach(backgroundSessions.reversed()) { session in
                    TranscribingChip(session: session, style: .notch, onCancel: { onCancelSession(session.id) })
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 360)
        .scrollIndicators(.hidden)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: engine.sessions.map(\.id))
    }
}

struct TranscribingChip: View {
    enum Style { case mini, notch }
    @ObservedObject var session: RecordingSession
    let style: Style
    let onCancel: () -> Void

    private var label: String {
        switch session.phase {
        case .queued: return String(localized: "Queued…")
        case .transcribing: return String(localized: "Transcribing…")
        case .delivering: return String(localized: "Delivering…")
        case .recording: return String(localized: "Recording…")
        case .done: return String(localized: "Completed")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProcessingIndicator(color: .white.opacity(0.86)).frame(width: 14, height: 14)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.82)).lineLimit(1)
            RecorderCancelButton(action: onCancel, helpLabel: "Cancel transcription", accessibilityLabel: "Cancel transcription")
                .scaleEffect(0.82)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(width: style == .mini ? 184 : 200)
        .background(Color.black.opacity(style == .mini ? 1.0 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: style == .mini ? 16 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: style == .mini ? 16 : 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
    }
}
