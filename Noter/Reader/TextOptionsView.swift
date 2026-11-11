import SwiftUI

/// Reading options for the Text view (the "Aa" button): theme, font, size, spacing,
/// margins and alignment. Changes apply live and are remembered.
struct TextOptionsView: View {
    @ObservedObject var session: DocumentSession

    private var appearance: Binding<TextAppearance> { $session.textAppearance }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Theme
                section("Theme") {
                    HStack(spacing: 10) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Button {
                                appearance.theme.wrappedValue = theme
                            } label: {
                                VStack(spacing: 4) {
                                    Text("Aa")
                                        .font(.system(size: 15, weight: .semibold, design: .serif))
                                        .foregroundStyle(Color(uiColor: theme.text))
                                        .frame(width: 42, height: 42)
                                        .background(Color(uiColor: theme.background), in: Circle())
                                        .overlay(Circle().strokeBorder(
                                            session.textAppearance.theme == theme ? Color.accentColor
                                                : Color.primary.opacity(0.15),
                                            lineWidth: session.textAppearance.theme == theme ? 2.5 : 1))
                                    Text(theme.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(theme.title) theme")
                        }
                    }
                }

                // Font
                section("Font") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(ReaderFont.allCases) { font in
                            let selected = session.textAppearance.font == font
                            Button {
                                appearance.font.wrappedValue = font
                            } label: {
                                Text(font.title)
                                    .font(Font(font.font(size: 16)))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Size
                section("Size") {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller")
                        Slider(value: $session.transcriptFontSize, in: 13...40, step: 1)
                        Image(systemName: "textformat.size.larger")
                        Text("\(Int(session.transcriptFontSize))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                    }
                }

                // Spacing
                section("Line spacing") {
                    HStack(spacing: 10) {
                        Image(systemName: "text.alignleft").imageScale(.small)
                        Slider(value: appearance.lineSpacing, in: 0.05...1.2)
                        Image(systemName: "text.alignleft").imageScale(.large)
                    }
                }
                section("Paragraph spacing") {
                    HStack(spacing: 10) {
                        Image(systemName: "paragraphsign").imageScale(.small)
                        Slider(value: appearance.paragraphSpacing, in: 0...2)
                        Image(systemName: "paragraphsign").imageScale(.large)
                    }
                }

                // Layout
                section("Margins") {
                    Picker("Margins", selection: appearance.width) {
                        ForEach(ReaderWidth.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                section("Pages") {
                    Toggle(isOn: appearance.twoPages) {
                        Label("Two pages side by side in landscape", systemImage: "book")
                    }
                    .font(.subheadline)
                }
                section("Alignment") {
                    Picker("Alignment", selection: appearance.justified) {
                        Label("Left", systemImage: "text.alignleft").tag(false)
                        Label("Justified", systemImage: "text.justify").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Button("Reset to defaults") {
                    session.textAppearance = TextAppearance()
                    session.transcriptFontSize = 21
                }
                .font(.footnote)
                .frame(maxWidth: .infinity)
            }
            .padding(18)
        }
        .frame(width: 360)
        .frame(maxHeight: 620)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}
