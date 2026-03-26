import SwiftUI

struct WizardStepWelcome: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "hare.fill")
                .font(.system(size: 72))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse, options: .repeating)

            Text(Strings.Wizard.welcomeTitle)
                .font(.largeTitle.bold())

            Text(Strings.Wizard.welcomeSubtitle)
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(Strings.Wizard.welcomeDescription)
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Spacer()

            Button(action: onStart) {
                Text(Strings.Wizard.getStarted)
                    .font(.title3.bold())
                    .frame(maxWidth: 240)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
                .frame(height: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
