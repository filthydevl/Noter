import SwiftUI

/// Shown at the bottom while the scribble pen is on: pen type, size, opacity, lasso,
/// ruler, undo / redo, and tidying handwriting into neat lettering.
struct ScribbleToolbar: View {
    @ObservedObject var session: DocumentSession
    @ObservedObject var settings: ScribbleSettings
    @State private var confirmClear = false

    var body: some View {
        // All pen types as buttons when there's room (landscape), in a menu otherwise.
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .padding(.horizontal, 16)
        .confirmationDialog("Clear all ink and tidied text on this page?", isPresented: $confirmClear,
                            titleVisibility: .visible) {
            Button("Clear page", role: .destructive) { session.pdfController?.clearCurrentPage() }
        }
    }

    private func pick(_ kind: InkKind) {
        settings.kind = kind
        settings.lasso = false
        session.tool = .pen
    }

    @ViewBuilder
    private func penTypes(compact: Bool) -> some View {
        if compact {
            Menu {
                Picker("Pen", selection: Binding(get: { settings.kind }, set: { pick($0) })) {
                    ForEach(InkKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
            } label: {
                Image(systemName: settings.kind.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(session.tool == .pen && !settings.lasso ? Color.accentColor : Color.primary)
                    .frame(width: 44, height: 36)
                    .background(Color.primary.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .accessibilityLabel("Pen type: \(settings.kind.title)")
        } else {
            ForEach(InkKind.allCases) { kind in
                tool(kind.symbol, kind.title,
                     selected: session.tool == .pen && !settings.lasso && settings.kind == kind) {
                    pick(kind)
                }
            }
        }
    }

    private func bar(compact: Bool) -> some View {
        HStack(spacing: 6) {
            penTypes(compact: compact)
            tool("lasso", "Lasso (select and move ink)", selected: settings.lasso && session.tool == .pen) {
                settings.lasso.toggle()
                session.tool = .pen
            }
            tool("ruler", "Ruler", selected: settings.ruler) { settings.ruler.toggle() }

            separator

            // Size, with a preview dot in the current color.
            Circle()
                .fill(settings.color.color.opacity(settings.opacity))
                .frame(width: dot, height: dot)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Slider(value: $settings.size, in: 0...1)
                .frame(width: compact ? 90 : 110)
                .accessibilityLabel("Pen size")
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: $settings.opacity, in: 0.15...1)
                .frame(width: compact ? 64 : 80)
                .accessibilityLabel("Opacity")

            separator

            tool("arrow.uturn.backward", "Undo") { session.inkUndo.undo() }
            tool("arrow.uturn.forward", "Redo") { session.inkUndo.redo() }

            separator

            // Handwriting → neat lettering.
            Button {
                session.pdfController?.tidyCurrentPage()
            } label: {
                Label("Tidy", systemImage: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Tidy handwriting on this page")

            Menu {
                Toggle(isOn: $settings.autoTidy) {
                    Label("Auto-tidy handwriting", systemImage: "wand.and.stars")
                }
                Picker("Lettering", selection: $settings.tidyStyle) {
                    ForEach(TidyStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Eraser", selection: $settings.eraser) {
                    ForEach(EraserKind.allCases) { Text($0.title).tag($0) }
                }
                Section {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Label("Clear this page", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Scribble options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .fixedSize()
    }

    private var dot: CGFloat { 4 + 18 * settings.size }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 24).padding(.horizontal, 2)
    }

    private func tool(_ symbol: String, _ label: String, selected: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .frame(width: 36, height: 36)
                .background(selected ? Color.primary.opacity(0.09) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
