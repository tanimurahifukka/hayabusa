import SwiftUI

struct WizardStepDownload: View {
    @Bindable var viewModel: WizardViewModel
    let settings: AppSettings

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: viewModel.isDownloadComplete ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(viewModel.isDownloadComplete ? .green : .blue)
                .contentTransition(.symbolEffect(.replace))

            Text(viewModel.isDownloadComplete ? Strings.Wizard.downloadComplete : Strings.Wizard.downloadTitle)
                .font(.title2.bold())

            if let error = viewModel.downloaderError {
                // Error state
                VStack(spacing: 12) {
                    Label(Strings.Errors.downloadFailed, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.headline)

                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(Strings.Errors.downloadFailedDetail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button(Strings.Wizard.downloadRetry) {
                        viewModel.retryDownload(settings: settings)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if viewModel.isDownloading {
                // Downloading state
                VStack(spacing: 12) {
                    ProgressView(value: viewModel.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 400)

                    HStack {
                        Text(Strings.Wizard.downloadProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(viewModel.downloadProgress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 400)

                    Text(viewModel.downloadCurrentFile)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Button(Strings.Wizard.downloadCancel) {
                        viewModel.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                }
            } else if viewModel.isDownloadComplete {
                // Complete state
                Label(Strings.Wizard.downloadComplete, systemImage: "checkmark")
                    .foregroundStyle(.green)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !viewModel.isDownloading && !viewModel.isDownloadComplete {
                viewModel.startDownload(settings: settings)
            }
        }
    }
}
