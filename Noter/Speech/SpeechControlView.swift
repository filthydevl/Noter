import SwiftUI
import AVFoundation

/// The small read-aloud control in the top-right corner of the page.
struct SpeechControlView: View {
    @ObservedObject var speech: SpeechController
    /// The bookmark button: show where the voice is reading.
    var locate: () -> Void = {}
    /// Stacked down the top of the tool strip (beside an open panel) instead of a
    /// floating capsule.
    var docked = false
    @State private var showSpeechify = false

    private var speechifyOn: Bool { speech.voiceEngine == .speechify && speech.hasSpeechifyKey }

    var body: some View {
        let stack = docked ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        return stack {
            Button {
                speech.togglePlay()
            } label: {
                Group {
                    if speech.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: speech.isPlaying ? "pause.fill" : "play.fill")
                    }
                }
                .frame(width: 20, height: 20)
                .frame(width: docked ? 38 : 20, height: docked ? 30 : 20)
            }
            .accessibilityLabel(speech.isPlaying ? "Pause reading" : "Read aloud")

            if speech.isActive {
                Button {
                    speech.stop()
                } label: {
                    Image(systemName: "stop.fill").frame(width: docked ? 38 : 18, height: docked ? 30 : 20)
                }
                .accessibilityLabel("Stop reading")

                Button(action: locate) {
                    Image(systemName: "bookmark.fill").frame(width: docked ? 38 : 18, height: docked ? 30 : 20)
                }
                .accessibilityLabel("Go to reading position")
            }

            Menu {
                // Speed
                Section("Speed") {
                    Picker("Speed", selection: $speech.speed) {
                        ForEach(SpeechController.speeds, id: \.self) { s in
                            Text(Self.speedLabel(s)).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle(isOn: $speech.autoSpeedUp) {
                        Label("Speed up every \(SpeechController.autoSpeedWords) words", systemImage: "hare")
                    }
                }

                // Voice: which kind, then which one.
                Section("Voice") {
                    Picker("Voices", selection: $speech.voiceEngine) {
                        ForEach(VoiceEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    if speechifyOn {
                        Menu {
                            ForEach(speech.speechifyLanguageVoices) { v in
                                Button {
                                    speech.chooseSpeechifyVoice(v.id)
                                } label: {
                                    if v.id == speech.speechifyVoiceID {
                                        Label("\(v.name) · \(v.detail)", systemImage: "checkmark")
                                    } else {
                                        Text("\(v.name) · \(v.detail)")
                                    }
                                }
                            }
                        } label: {
                            Label("Speechify voice", systemImage: "waveform")
                        }
                    } else {
                        Menu {
                            ForEach(speech.voiceSections, id: \.title) { section in
                                Section(section.title) {
                                    ForEach(section.voices, id: \.identifier) { v in
                                        Button {
                                            speech.chooseVoice(v.identifier)
                                        } label: {
                                            if v.identifier == speech.voiceID {
                                                Label(SpeechController.voiceTitle(v), systemImage: "checkmark")
                                            } else {
                                                Text(SpeechController.voiceTitle(v))
                                            }
                                        }
                                    }
                                }
                            }
                            Text("More voices: Settings › Accessibility › Spoken Content › Voices.")
                        } label: {
                            Label("Built-in voice", systemImage: "person.wave.2")
                        }
                    }
                    Button {
                        showSpeechify = true
                    } label: {
                        Label(speech.hasSpeechifyKey ? "Speechify settings…" : "Set up Speechify…",
                              systemImage: "gearshape")
                    }
                    if speechifyOn, let problem = speech.speechifyProblem {
                        Text(problem)
                    }
                }

                // What to leave out.
                Section {
                    Menu {
                        ForEach(SkipOptions.items) { item in
                            Toggle(item.title, isOn: Binding(
                                get: { speech.skip.contains(item.option) },
                                set: { on in
                                    var options = speech.skip
                                    if on {
                                        options.insert(item.option)
                                    } else {
                                        options.remove(item.option)
                                    }
                                    speech.skip = options
                                }))
                        }
                        Text("Skipped text is dimmed in the Text view.")
                    } label: {
                        Label("Skip while reading", systemImage: "forward")
                    }
                }
            } label: {
                Text(Self.speedLabel(speech.speed))
                    .font(.system(size: docked ? 12 : 14, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: docked ? 38 : 34, minHeight: docked ? 30 : 0)
            }
            .onAppear {
                speech.refreshVoices()
                speech.warmUpSpeechify()
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, docked ? 0 : 14)
        .padding(.vertical, docked ? 4 : 10) // 40 tall, like the top bar's buttons
        .background {
            if !docked {
                Capsule().fill(.regularMaterial)
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            }
        }
        .sheet(isPresented: $showSpeechify) {
            SpeechifySettingsView(speech: speech)
        }
    }

    static func speedLabel(_ s: Double) -> String {
        let text = s == s.rounded() ? String(format: "%.0f", s) : String(format: "%.1f", s)
        return "\(text)×"
    }
}
