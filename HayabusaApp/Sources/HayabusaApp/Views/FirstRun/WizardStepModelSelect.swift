import SwiftUI

struct WizardStepModelSelect: View {
    @Bindable var viewModel: WizardViewModel

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                Text(Strings.Wizard.modelSelectTitle)
                    .font(.title2.bold())
                Text(Strings.Wizard.modelSelectDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Mode picker: installed vs download
            Picker("", selection: $viewModel.selectionMode) {
                Text(Strings.Wizard.modelInstalledTab)
                    .tag(WizardViewModel.ModelSelectionMode.local)
                Text(Strings.Wizard.modelDownloadTab)
                    .tag(WizardViewModel.ModelSelectionMode.tier)
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            if viewModel.selectionMode == .local {
                localModelList
            } else {
                tierCards
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            viewModel.scanLocalModels()
        }
    }

    // MARK: - Installed models list

    private var localModelList: some View {
        Group {
            if viewModel.localModels.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(Strings.Wizard.modelNoneInstalled)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 200)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(viewModel.localModels) { model in
                            localModelRow(model)
                        }
                    }
                    .padding(.horizontal, 40)
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func localModelRow(_ model: WizardViewModel.LocalModel) -> some View {
        let isSelected = viewModel.selectedLocalModel?.id == model.id
        return Button {
            viewModel.selectedLocalModel = model
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.headline)
                    Text(model.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.backend.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(model.backend == "mlx" ? Color.purple.opacity(0.15) : Color.blue.opacity(0.15))
                        .foregroundStyle(model.backend == "mlx" ? .purple : .blue)
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    Text(model.sizeDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Download tier cards

    private var tierCards: some View {
        HStack(spacing: 16) {
            ForEach(WizardViewModel.ModelTier.allCases, id: \.self) { tier in
                ModelCard(
                    name: tier.displayName,
                    modelName: tier.huggingFaceId,
                    description: tier.description,
                    detail: tier.detail,
                    memoryInfo: tier.memoryInfo,
                    badge: tier.badge,
                    isSelected: viewModel.selectedModel == tier,
                    action: { viewModel.selectedModel = tier }
                )
            }
        }
    }
}
