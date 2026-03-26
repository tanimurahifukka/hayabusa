import SwiftUI

struct SetupWizardView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = WizardViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            if viewModel.currentStep != .welcome {
                stepIndicator
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
            }

            // Step content
            Group {
                switch viewModel.currentStep {
                case .welcome:
                    WizardStepWelcome {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            viewModel.goNext()
                        }
                    }
                case .modelSelect:
                    WizardStepModelSelect(viewModel: viewModel)
                case .download:
                    WizardStepDownload(viewModel: viewModel, settings: appState.settings)
                case .cluster:
                    WizardStepCluster(viewModel: viewModel, scanner: appState.bonjourScanner)
                case .complete:
                    WizardStepComplete(viewModel: viewModel, appState: appState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.3), value: viewModel.currentStep)

            // Navigation buttons (hidden on welcome and complete)
            if viewModel.currentStep != .welcome && viewModel.currentStep != .complete {
                navigationBar
                    .padding(.horizontal, 24)
                    .padding(.bottom, 20)
            }
        }
        .frame(width: 700, height: 520)
    }

    // MARK: - Step Indicator

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(1..<viewModel.stepCount, id: \.self) { i in
                Capsule()
                    .fill(i <= viewModel.currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack {
            Button(Strings.Wizard.back) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    viewModel.goBack()
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(Strings.Wizard.next) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    viewModel.goNext()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canGoNext())
        }
    }
}
