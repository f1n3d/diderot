import SwiftUI
import DocmostKit

/// Floating capsule bar above the active block (callout type, code language, column actions).
struct FloatingBlockBar<Content: View>: View {
    var verticalPadding: CGFloat = 3
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) { content }
                .padding(.horizontal, 6)
                .padding(.vertical, verticalPadding)
        }
        .background(.regularMaterial, in: Capsule())
    }
}

private extension Text {
    /// Option in the callout and code bars.
    func barOption(selected: Bool) -> some View {
        font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .contentShape(Capsule())
    }
}

/// Switches the type of the active callout.
struct CalloutTypeBar: View {
    let model: DocumentModel
    let path: [Int]
    let current: CalloutKind

    var body: some View {
        FloatingBlockBar {
            ForEach(CalloutKind.allCases, id: \.self) { kind in
                Button {
                    Task { await model.setAttributes(of: NodeRef(path: path, id: nil), ["type": .string(kind.rawValue)]) }
                } label: {
                    Text(kind.title).barOption(selected: kind == current)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("callout-\(kind.rawValue)")
            }
        }
    }
}

/// Picks the language of the active code block.
struct CodeLanguageBar: View {
    let model: DocumentModel
    let path: [Int]
    let current: String?

    private static let languages = [
        "plaintext", "swift", "javascript", "typescript", "python", "json", "bash", "shell", "html", "css", "sql",
        "yaml", "markdown", "java", "kotlin", "go", "rust", "c", "cpp", "csharp", "php", "ruby", "xml", "mermaid",
    ]

    var body: some View {
        FloatingBlockBar {
            ForEach(Self.languages, id: \.self) { language in
                Button {
                    Task { await model.setAttributes(of: NodeRef(path: path, id: nil), ["language": language == "plaintext" ? .null : .string(language)]) }
                } label: {
                    Text(language).barOption(selected: (current ?? "plaintext") == language)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

extension EnvironmentValues {
    /// The page shows the block's "…" (`BlockActionsButton`) at its top right, over the block.
    @Entry var showsBlockActions = false
}

extension View {
    /// Keeps text inside a block clear of the block's "…" at its top right, where the page shows one. `inset`: room
    /// the block already has there (a callout's padding); `applies`: whether this part sits at the top right.
    func clearOfBlockActions(inset: CGFloat = 0, applies: Bool = true) -> some View {
        modifier(ClearOfBlockActions(inset: inset, applies: applies))
    }
}

private struct ClearOfBlockActions: ViewModifier {
    let inset: CGFloat
    let applies: Bool
    @Environment(\.showsBlockActions) private var showsBlockActions
    /// The button's width: a `.title3` symbol with 6 points on each side, growing with the text size as it does.
    @ScaledMetric(relativeTo: .title3) private var buttonWidth: CGFloat = 34

    func body(content: Content) -> some View {
        content
            .padding(.trailing, showsBlockActions && applies ? max(buttonWidth - inset, 0) : 0)
            // Blocks inside have a button of their own, or none.
            .environment(\.showsBlockActions, false)
    }
}

/// The "…" that opens a block's actions.
struct BlockActionsButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "ellipsis.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Block actions")
        .accessibilityIdentifier("block-actions")
    }
}
