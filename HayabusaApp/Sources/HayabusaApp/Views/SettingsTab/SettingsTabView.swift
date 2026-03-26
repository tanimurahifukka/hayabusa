import SwiftUI

struct SettingsTabView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = SettingsViewModel()
    @State private var showSaveConfirmation = false

    var body: some View {
        Form {
            // Server section
            Section("Server") {
                LabeledContent("Hayabusa Binary") {
                    HStack {
                        TextField("Path to Hayabusa binary", text: Binding(
                            get: { appState.settings.hayabusaBinaryPath },
                            set: { appState.settings.hayabusaBinaryPath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button("Browse") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.settings.hayabusaBinaryPath = url.path
                            }
                        }
                    }
                }

                LabeledContent("Model Path") {
                    HStack {
                        TextField("Model path or HuggingFace ID", text: Binding(
                            get: { appState.settings.modelPath },
                            set: { appState.settings.modelPath = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button("Browse") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = true
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.settings.modelPath = url.path
                            }
                        }
                    }
                }

                Picker("Backend", selection: Binding(
                    get: { appState.settings.backend },
                    set: { appState.settings.backend = $0 }
                )) {
                    Text("llama.cpp").tag("llama")
                    Text("MLX").tag("mlx")
                }

                ValidatedField(label: "Port", text: $viewModel.portText, error: viewModel.validationErrors["port"])
                ValidatedField(label: "Slots", text: $viewModel.slotsText, error: viewModel.validationErrors["slots"])
            }

            // Backend-specific
            if appState.settings.backend == "llama" {
                Section("llama.cpp") {
                    ValidatedField(label: "Context per Slot", text: $viewModel.ctxPerSlotText, error: viewModel.validationErrors["ctxPerSlot"])
                }
            } else {
                Section("MLX") {
                    ValidatedField(label: "Max Memory (GB)", text: $viewModel.maxMemoryText, error: viewModel.validationErrors["maxMemory"])
                    ValidatedField(label: "Max Context", text: $viewModel.maxContextText, error: viewModel.validationErrors["maxContext"])
                }
            }

            // Cluster section
            Section("Cluster") {
                Toggle("Enable Cluster Mode", isOn: Binding(
                    get: { appState.settings.clusterEnabled },
                    set: { appState.settings.clusterEnabled = $0 }
                ))

                if appState.settings.clusterEnabled {
                    ValidatedField(label: "Spillover Threshold", text: $viewModel.spilloverText, error: viewModel.validationErrors["spillover"])
                    PeerManagementView(peers: Binding(
                        get: { appState.settings.peers },
                        set: { appState.settings.peers = $0 }
                    ))
                }
            }

            // App section
            Section("Application") {
                Toggle("Auto-start server on launch", isOn: Binding(
                    get: { appState.settings.autoStartServer },
                    set: { appState.settings.autoStartServer = $0 }
                ))
                Toggle("Launch at login", isOn: Binding(
                    get: { appState.settings.launchAtLogin },
                    set: { appState.settings.launchAtLogin = $0 }
                ))
            }

            // Save button
            Section {
                HStack {
                    Spacer()
                    Button("Save Settings") {
                        if viewModel.save(to: appState.settings) {
                            showSaveConfirmation = true
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .alert("Settings Saved", isPresented: $showSaveConfirmation) {
            Button("OK") {}
        } message: {
            Text("Restart the server for changes to take effect.")
        }
        .onAppear {
            viewModel.load(from: appState.settings)
        }
    }
}

private struct ValidatedField: View {
    let label: String
    @Binding var text: String
    let error: String?

    var body: some View {
        LabeledContent(label) {
            VStack(alignment: .trailing, spacing: 2) {
                TextField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
