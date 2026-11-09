import SwiftUI

/// The Colors panel: name your highlight colors after what they stand for in this
/// document ("Ideas", "Concepts", "People"…), add colors from the color wheel, and
/// choose between a new color after every highlight or picking them yourself. Names
/// are a guide for you; they don't change the highlights.
struct ColorsListView: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var palette: ColorPalette
    var onClose: () -> Void
    @State private var newColor = Color(red: 0.55, green: 0.45, blue: 0.95)

    var body: some View {
        let counts = Dictionary(grouping: session.highlights, by: \.color).mapValues(\.count)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Colors")
                        .font(.title3.weight(.semibold))
                    Text(palette.autoSwitch ? "A new color after every highlight"
                         : "You pick the color · a new shade for each highlight in it")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) { PanelIcon(symbol: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close colors")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Picker("Color mode", selection: $palette.autoSwitch) {
                Text("Auto switch").tag(true)
                Text("Manual").tag(false)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(palette.colors) { c in
                        ColorRow(color: c, initialName: palette.name(c) ?? "", count: counts[c] ?? 0,
                                 selected: c == session.color, removable: palette.colors.count > 1,
                                 placeholder: "Name it — e.g. Ideas, Concepts",
                                 pick: {
                                     session.color = c
                                     session.tool = .pen
                                 },
                                 rename: { palette.setName($0, for: c) },
                                 remove: {
                                     palette.remove(c)
                                     if session.color == c { session.color = palette.colors.first ?? .yellow }
                                 })
                    }

                    // Add a color.
                    HStack(spacing: 12) {
                        ColorPicker("New color", selection: $newColor, supportsOpacity: false)
                            .labelsHidden()
                        Text("Pick a color from the wheel or palette")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            let c = palette.add(UIColor(newColor))
                            session.color = c
                            session.tool = .pen
                        } label: {
                            Label("Add", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .accessibilityLabel("Add color")
                    }
                    .padding(12)
                    .background(Color(.systemBackground).opacity(0.75),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Circled words.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Circled words")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ColorRow(color: .maroon, initialName: palette.name(.maroon) ?? "", count: counts[.maroon] ?? 0,
                                 selected: false, removable: false, placeholder: "Word",
                                 pick: {}, rename: { palette.setName($0, for: .maroon) }, remove: {})
                        Text("Circle a word or short phrase with the highlighter (PDF or Text view): it’s highlighted and circled in this color. Then underline its definition — as many lines as you need — and tap ✓ next to the word to save it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

private struct ColorRow: View {
    let color: HighlightColor
    let initialName: String
    let count: Int
    let selected: Bool
    let removable: Bool
    let placeholder: String
    let pick: () -> Void
    let rename: (String) -> Void
    let remove: () -> Void
    @State private var name = ""
    @State private var loaded = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: pick) {
                Circle()
                    .fill(color.color)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.7 : 0.12),
                                                   lineWidth: selected ? 2.5 : 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Highlight with \(initialName.isEmpty ? color.name : initialName)")

            TextField(placeholder, text: $name)
                .font(.body)
                .textInputAutocapitalization(.words)
                .accessibilityLabel("Name for \(color.name)")
                .onAppear {
                    if !loaded {
                        name = initialName
                        loaded = true
                    }
                }
                .onChange(of: name) { _, new in
                    if loaded { rename(new) }
                }

            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) highlights")

            if removable {
                Menu {
                    Button(role: .destructive, action: remove) {
                        Label("Remove color", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .accessibilityLabel("More for \(color.name)")
            }
        }
        .padding(12)
        .background(Color(.systemBackground).opacity(0.75), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
