import SwiftUI
import SwiftData

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var engine: VoiceInkEngine
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var mainWindowNavigation: MainWindowNavigation
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @Query(Self.recentTranscriptionsDescriptor()) private var recentTranscriptions: [Transcription]
    @State private var isQuitting = false

    var body: some View {
        VStack {
            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Complete Onboarding") {
                showMainWindow()
            }

            Divider()

            Button("Quit VoiceInk") {
                quitApplication()
            }
            .disabled(isQuitting)
        }
    }

    private var completedOnboardingMenu: some View {
        Group {
            ForEach(recentTranscriptions) { transcription in
                let status = status(for: transcription)
                Button {
                    if status == "Completed" {
                        _ = ClipboardManager.copyToClipboard(transcription.text)
                    } else if status == "Failed", transcription.retryCount == 0 {
                        Task { @MainActor in
                            await engine.retryTranscription(transcription)
                        }
                    }
                } label: {
                    HStack {
                        Text(firstNonemptyLine(of: transcription.text))
                            .lineLimit(1)
                        Spacer()
                        Text(transcription.timestamp, style: .time)
                            .foregroundStyle(.secondary)
                        Text(status)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(status == "Failed" && transcription.retryCount > 0)
            }

            Divider()

            Button("History") {
                menuBarManager.openHistoryWindow()
            }

            Button("Settings") {
                showMainWindowAndNavigate(to: "Settings")
            }

            Button("Quit VoiceInk") {
                quitApplication()
            }
            .disabled(isQuitting)
        }
    }

    private static func recentTranscriptionsDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { transcription in
                (transcription.transcriptionStatus ?? "") != "canceled"
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 6
        return descriptor
    }

    private func firstNonemptyLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private func status(for transcription: Transcription) -> String {
        if let session = engine.sessions.first(where: { $0.transcriptionID == transcription.id }) {
            switch session.phase {
            case .queued, .recording:
                return "Queued"
            case .transcribing, .delivering:
                return "Transcribing"
            case .done:
                break
            }
        }

        if transcription.transcriptionStatus == "failed" {
            return "Failed"
        }
        if transcription.transcriptionStatus == "pending" || transcription.transcriptionStatus == nil {
            return "Queued"
        }
        return "Completed"
    }

    private func showMainWindow() {
        let existingWindow = WindowManager.shared.currentMainWindow()
        menuBarManager.activateForPresentedWindow()

        if existingWindow == nil {
            WindowManager.shared.prepareForUserRequestedMainWindow()
            openWindow(id: AppWindowID.main)
        } else {
            openWindow(id: AppWindowID.main)
            WindowManager.shared.showMainWindow()
        }
    }
    private func quitApplication() {
        guard !isQuitting else { return }
        isQuitting = true
        Task { @MainActor in
            await engine.resetRecordingSession()
            NSApplication.shared.terminate(nil)
        }
    }

    private func showMainWindowAndNavigate(to destination: String) {
        mainWindowNavigation.navigate(to: destination)
        showMainWindow()
    }
}
