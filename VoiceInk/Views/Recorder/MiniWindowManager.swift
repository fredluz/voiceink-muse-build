import AppKit
import SwiftUI
import os

@MainActor
class MiniWindowManager {
    private var windowController: NSWindowController?
    private var panel: MiniRecorderPanel?
    private let makeView: () -> AnyView
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MiniWindowManager")

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
            AnyView(MiniRecorderStackView(
                engine: engine,
                recorder: recorder,
                assistantSession: assistantSession,
                onRecordButtonTapped: onRecordButtonTapped,
                onCloseTapped: onCloseTapped,
                onCancelTapped: onCancelTapped,
                onAssistantFollowUp: onAssistantFollowUp,
                onCancelSession: onCancelSession
            ))
        }
    }

    @discardableResult
    func show() -> Bool {
        if panel == nil { initializeWindow() }
        guard let panel else { return false }
        return panel.show()
    }

    func hide() { deinitializeWindow() }
    func destroyWindow() { deinitializeWindow() }

    private func initializeWindow() {
        deinitializeWindow()
        guard let metrics = MiniRecorderPanel.calculateWindowMetrics() else {
            logger.error("Mini panel not created: no screen available")
            return
        }
        let newPanel = MiniRecorderPanel(contentRect: metrics)
        newPanel.contentView = NSHostingController(rootView: makeView()).view
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
