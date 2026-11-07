import SwiftUI
import AVFoundation

/// The small read-aloud control in the top-right corner of the page.
struct SpeechControlView: View {
    @ObservedObject var speech: SpeechController
    /// The bookmark button: show where the voice is reading.
    var locate: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
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
            }
            .accessibilityLabel(speech.isPlaying ? "Pause reading" : "Read aloud")

            if speech.isActive {
                Button {
                    speech.stop()
                } label: {
                    Image(systemName: "stop.fill").frame(width: 18, height: 20)
                }
                .accessibilityLabel("Stop reading")

                Button(action: locate) {
                    Image(systemName: "bookmark.fill").frame(width: 18, height: 20)
                }
                .accessibilityLabel("Go to reading position")
            }

            Menu {
                Picker("Speed", selection: $speech.speed) {
                    ForEach(SpeechController.speeds, id: \.self) { s in
                        Text(Self.speedLabel(s)).tag(s)
                    }
                }
                Section {
                    Toggle(isOn: $speech.followVoiceOver) {
                        Label("Use VoiceOver's voice", systemImage: "accessibility")
                    }
                    if speech.followVoiceOver {
                        Text(speech.voiceOverRunning
                             ? "VoiceOver is on: reading with its voice and speed (set the speed with the rotor). Turn this off to use the speeds above."
                             : "Only while VoiceOver is on. Until then Noter reads with the voice below.")
                    }
                }
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
                Menu("Voice") {
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
                }
                if speech.hasNaturalVoice {
                    Text("More voices: Settings › Accessibility › Spoken Content › Voices › English.")
                } else {
                    Text("These voices sound robotic. Download a Premium voice in Settings › Accessibility › Spoken Content › Voices › English.")
                }
            } label: {
                Text(Self.speedLabel(speech.speed))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .frame(minWidth: 34)
            }
            .onAppear { speech.refreshVoices() }
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }

    static func speedLabel(_ s: Double) -> String {
        let text = s == s.rounded() ? String(format: "%.0f", s) : String(format: "%g", s)
        return "\(text)×"
    }
}
