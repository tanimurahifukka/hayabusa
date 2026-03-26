import SwiftUI

struct PeerManagementView: View {
    @Binding var peers: [String]
    @State private var newPeer = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Peers")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            // Peer list
            ForEach(Array(peers.enumerated()), id: \.offset) { index, peer in
                HStack {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    Text(peer)
                        .font(.caption.monospaced())
                    Spacer()
                    Button {
                        peers.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Add peer
            HStack {
                TextField("host:port (e.g. 192.168.1.10:8080)", text: $newPeer)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                Button {
                    addPeer()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(newPeer.isEmpty)
            }

            if let error = validationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func addPeer() {
        let trimmed = newPeer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        // Basic validation: should be host:port
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else {
            validationError = "Format: host:port (e.g. 192.168.1.10:8080)"
            return
        }

        if peers.contains(trimmed) {
            validationError = "Peer already exists"
            return
        }

        peers.append(trimmed)
        newPeer = ""
        validationError = nil
    }
}
