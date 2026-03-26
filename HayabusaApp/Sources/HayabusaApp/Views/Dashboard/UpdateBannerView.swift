import SwiftUI

struct UpdateBannerView: View {
    let updater: SparkleUpdater

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)

            Text(Strings.Update.available)
                .font(.subheadline)

            Spacer()

            Button(Strings.Update.updateNow) {
                updater.checkForUpdates()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
