import SwiftUI

struct ModelDownloadView: View {
    @Bindable var viewModel: ModelViewModel

    var body: some View {
        GroupBox("Download from HuggingFace") {
            VStack(spacing: 12) {
                HStack {
                    TextField("Model ID (e.g. mlx-community/Qwen3.5-9B-MLX-4bit)", text: $viewModel.downloadModelId)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        let dest = NSHomeDirectory() + "/models"
                        viewModel.downloadModel(destination: dest)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.downloadModelId.isEmpty || viewModel.downloader.isDownloading)
                }

                if viewModel.downloader.isDownloading {
                    VStack(spacing: 4) {
                        ProgressView(value: viewModel.downloader.progress) {
                            HStack {
                                Text("Downloading: \(viewModel.downloader.currentFile)")
                                    .font(.caption)
                                Spacer()
                                Text(Formatters.percentage(viewModel.downloader.progress))
                                    .font(.caption.monospacedDigit())
                            }
                        }

                        Button("Cancel") {
                            viewModel.downloader.cancel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if let error = viewModel.downloader.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !viewModel.downloader.isDownloading && viewModel.downloader.progress >= 1.0 {
                    Label("Download complete!", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
            .padding()
        }
    }
}
