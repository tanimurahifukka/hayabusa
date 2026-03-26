import SwiftUI

struct ModelTabView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ModelViewModel()

    var body: some View {
        VStack(spacing: 16) {
            // Download section
            ModelDownloadView(viewModel: viewModel)
                .padding(.horizontal)

            Divider()

            // Local models
            GroupBox("Local Models") {
                if viewModel.localModels.isEmpty {
                    ContentUnavailableView(
                        "No Models Found",
                        systemImage: "brain",
                        description: Text("Download a model or scan directories to find local models")
                    )
                    .frame(height: 150)
                } else {
                    List(viewModel.localModels) { model in
                        HStack {
                            Image(systemName: model.backend == "llama" ? "doc.zipper" : "folder.fill")
                                .foregroundStyle(model.backend == "llama" ? .orange : .blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.name)
                                    .font(.body.bold())
                                Text(model.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 2) {
                                Text(model.sizeFormatted)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text(model.backend.uppercased())
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(model.backend == "llama" ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                                    .cornerRadius(3)
                            }

                            Button("Select") {
                                viewModel.selectModel(model, settings: appState.settings)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(appState.settings.modelPath == model.path)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(.horizontal)

            HStack {
                Button("Scan Models") {
                    viewModel.scanModels(settings: appState.settings)
                }
                .buttonStyle(.bordered)

                Spacer()

                if !appState.settings.modelPath.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Current: \(appState.settings.modelPath.components(separatedBy: "/").last ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical)
        .onAppear {
            viewModel.scanModels(settings: appState.settings)
        }
    }
}
