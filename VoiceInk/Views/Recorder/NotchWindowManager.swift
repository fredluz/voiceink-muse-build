import SwiftUI
import AppKit

@MainActor
class NotchWindowManager {
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?

    private let makeView: () -> AnyView

    init(
        engine: VoiceInkEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onCancelTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void,
        onCancelSession: @escaping (UUID) -> Void
    ) {
        self.makeView = {
            AnyView(
                NotchRecorderStackView(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onCancelTapped: onCancelTapped,
                    onAssistantFollowUp: onAssistantFollowUp,
                    onCancelSession: onCancelSession
                )
            )
        }
    }

    @discardableResult
    func show() -> Bool {
        if panel == nil { initializeWindow() }
        guard let panel else { return false }
        return panel.show()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func destroyWindow() {
        deinitializeWindow()
    }

    private func initializeWindow() {
        deinitializeWindow()
        guard let metrics = NotchRecorderPanel.calculateWindowMetrics() else { return }
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        let hostingController = NotchRecorderHostingController(rootView: makeView())
        newPanel.contentView = hostingController.view
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }
}
