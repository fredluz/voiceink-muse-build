import SwiftUI

struct OnboardingModelScreen: View {
    let contentMaxWidth: CGFloat
    let providerOptions: [any CloudProvider]
    @Binding var selectedProviderKey: String
    let isSetupReady: Bool
    let onVerificationChanged: () -> Void
    let onBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepScreen(
            stage: .model,
            contentMaxWidth: contentMaxWidth
        ) {
            OnboardingTranscriptionSetupCard(
                providerOptions: providerOptions,
                selectedProviderKey: $selectedProviderKey,
                onVerificationChanged: onVerificationChanged
            )
        } bottomBar: {
            OnboardingBottomBar(
                leadingTitle: "Back",
                primaryTitle: "Continue",
                isPrimaryEnabled: isSetupReady,
                onLeading: onBack,
                onPrimary: onContinue
            )
        }
    }
}
