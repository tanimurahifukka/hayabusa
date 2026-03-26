import SwiftUI

struct LogView: View {
    let lines: [String]
    @State private var autoScroll = true
    @State private var copied = false

    var body: some View {
        GroupBox("Server Log") {
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Text("\(lines.count) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        let text = lines.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied!" : "Copy All", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(lines.isEmpty)

                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(logColor(for: line))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: lines.count) { _, _ in
                        if autoScroll, let last = lines.indices.last {
                            withAnimation {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private func logColor(for line: String) -> Color {
        if line.contains("[Error]") || line.contains("error") || line.contains("ERROR") || line.contains("Fatal") {
            return .red
        }
        if line.contains("[Warning]") || line.contains("warning") {
            return .orange
        }
        if line.hasPrefix("[") {
            return .blue
        }
        return .primary
    }
}
