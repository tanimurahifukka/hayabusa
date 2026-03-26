import SwiftUI

struct WizardStepComplete: View {
    @Bindable var viewModel: WizardViewModel
    let appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if viewModel.serverStarted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: viewModel.serverStarted)

                Text(Strings.Wizard.serverStarted)
                    .font(.title2.bold())
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 64))
                    .foregroundStyle(.blue)

                Text(Strings.Wizard.completeTitle)
                    .font(.title2.bold())

                Text(Strings.Wizard.completeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                if !viewModel.serverStarted {
                    Button {
                        viewModel.applySettings(to: appState.settings)
                        viewModel.applyClusterPeers(
                            to: appState.settings,
                            nodes: appState.bonjourScanner.discoveredNodes
                        )
                        appState.startServer()
                        viewModel.serverStarted = true
                    } label: {
                        Label(Strings.Wizard.startServer, systemImage: "play.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: 280)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button(Strings.Wizard.skipStart) {
                        viewModel.applySettings(to: appState.settings)
                        viewModel.applyClusterPeers(
                            to: appState.settings,
                            nodes: appState.bonjourScanner.discoveredNodes
                        )
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                } else {
                    Button(Strings.Wizard.closeWindow) {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }

            Spacer()
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
