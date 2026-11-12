import SwiftUI

/// Speechify set-up: paste your API key once (it's kept in the iPad's Keychain),
/// then pick a voice. Tapping a voice plays its preview.
struct SpeechifySettingsView: View {
    @ObservedObject var speech: SpeechController
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var checking = false
    @State private var message: String?
    @State private var search = ""
    @State private var showAllLanguages = false

    private var voices: [SpeechifyVoice] {
        let base = showAllLanguages ? speech.speechifyVoices : speech.speechifyLanguageVoices
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.detail.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Read with", selection: $speech.voiceEngine) {
                        ForEach(VoiceEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("If Speechify can't be reached, Noter keeps reading with the built-in voice from the same word.")
                }

                Section {
                    if speech.hasSpeechifyKey {
                        HStack {
                            Label("API key saved", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button("Remove", role: .destructive) { speech.removeSpeechifyKey() }
                        }
                    }
                    SecureField(speech.hasSpeechifyKey ? "Replace key" : "Paste your API key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(save)
                    Button(action: save) {
                        if checking {
                            ProgressView()
                        } else {
                            Text("Save key")
                        }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let problem = speech.speechifyProblem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Speechify API key")
                } footer: {
                    Text("Stored only in this iPad's Keychain. Read-aloud audio is cached on the iPad, so pages you've already heard replay instantly and aren't billed again.")
                }

                if speech.hasSpeechifyKey {
                    Section {
                        Toggle("All languages", isOn: $showAllLanguages)
                        if voices.isEmpty {
                            HStack {
                                ProgressView()
                                Text("Loading voices…").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(voices) { v in
                            Button {
                                speech.chooseSpeechifyVoice(v.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(v.name).foregroundStyle(.primary)
                                        if !v.detail.isEmpty {
                                            Text(v.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if v.id == speech.speechifyVoiceID {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    } else if v.preview != nil {
                                        Image(systemName: "play.circle").foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Voice")
                    } footer: {
                        Text("Tap a voice to choose it and hear a sample.")
                    }
                }
            }
            .searchable(text: $search, prompt: "Search voices")
            .navigationTitle("Speechify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await speech.refreshSpeechifyVoices(force: true) }
        }
    }

    private func save() {
        let k = key
        guard !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !checking else { return }
        checking = true
        message = nil
        Task { @MainActor in
            message = await speech.saveSpeechifyKey(k)
            if message == nil {
                key = ""
                message = "Key saved and verified."
            }
            checking = false
        }
    }
}
