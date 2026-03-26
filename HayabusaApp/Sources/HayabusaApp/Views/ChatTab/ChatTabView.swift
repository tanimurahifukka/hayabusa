import SwiftUI

struct ChatTabView: View {
    @Environment(AppState.self) private var appState
    @State private var input = ""
    @State private var messages: [(role: String, content: String)] = []
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(messages.enumerated()), id: \.offset) { i, msg in
                            ChatBubble(role: msg.role, content: msg.content)
                                .id(i)
                        }
                        if isLoading {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Thinking...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .id("loading")
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo(messages.count - 1, anchor: .bottom)
                    }
                }
                .onChange(of: isLoading) { _, loading in
                    if loading {
                        withAnimation { proxy.scrollTo("loading", anchor: .bottom) }
                    }
                }
            }

            if let err = errorText {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            // Input
            HStack(spacing: 8) {
                TextField("Message...", text: $input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit { send() }

                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? .blue : .gray)
                .disabled(!canSend)
            }
            .padding(12)
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty
            && !isLoading
            && appState.serverState == .running
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !isLoading else { return }

        input = ""
        errorText = nil
        messages.append((role: "user", content: text))
        isLoading = true

        let apiMessages = messages.map { ["role": $0.role, "content": $0.content] }

        Task {
            do {
                let response = try await appState.apiClient.chatCompletion(
                    messages: apiMessages,
                    maxTokens: 1024,
                    temperature: 0.7
                )
                messages.append((role: "assistant", content: response.text))
            } catch {
                errorText = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct ChatBubble: View {
    let role: String
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: role == "user" ? "person.circle.fill" : "hare.fill")
                .font(.title3)
                .foregroundStyle(role == "user" ? .blue : .orange)

            Text(content)
                .textSelection(.enabled)
                .padding(10)
                .background(role == "user" ? Color.blue.opacity(0.1) : Color.orange.opacity(0.1))
                .cornerRadius(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
