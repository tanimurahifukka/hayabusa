import SwiftUI

struct WizardStepCluster: View {
    @Bindable var viewModel: WizardViewModel
    let scanner: BonjourScanner

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 40))
                .foregroundStyle(.blue)

            Text(Strings.Wizard.clusterTitle)
                .font(.title2.bold())

            Text(Strings.Wizard.clusterDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 450)

            // Two-option picker
            HStack(spacing: 16) {
                clusterOptionButton(
                    title: Strings.Wizard.clusterStandalone,
                    description: Strings.Wizard.clusterStandaloneDescription,
                    icon: "desktopcomputer",
                    isSelected: viewModel.clusterChoice == .standalone
                ) {
                    viewModel.clusterChoice = .standalone
                    scanner.stopScan()
                }

                clusterOptionButton(
                    title: Strings.Wizard.clusterConnect,
                    description: Strings.Wizard.clusterConnectDescription,
                    icon: "network",
                    isSelected: viewModel.clusterChoice == .connect
                ) {
                    viewModel.clusterChoice = .connect
                    scanner.startScan()
                }
            }

            // Node discovery section (when connect is chosen)
            if viewModel.clusterChoice == .connect {
                VStack(spacing: 12) {
                    if scanner.isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(Strings.Wizard.clusterScanning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !scanner.discoveredNodes.isEmpty {
                        Text(String(format: Strings.Wizard.clusterFound, scanner.discoveredNodes.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(spacing: 4) {
                            ForEach(scanner.discoveredNodes) { node in
                                nodeRow(node: node)
                            }
                        }
                        .frame(maxWidth: 400)
                    } else if !scanner.isScanning {
                        Text(Strings.Wizard.clusterNoneFound)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func clusterOptionButton(
        title: String,
        description: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 200, height: 120)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func nodeRow(node: DiscoveredNode) -> some View {
        let isSelected = viewModel.selectedPeerIds.contains(node.id)
        return Button {
            if isSelected {
                viewModel.selectedPeerIds.remove(node.id)
            } else {
                viewModel.selectedPeerIds.insert(node.id)
            }
        } label: {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                VStack(alignment: .leading) {
                    Text(node.name)
                        .font(.subheadline)
                    Text(node.peerString)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
