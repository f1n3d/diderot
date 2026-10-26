import SwiftUI

/// "Get started with" below an empty page's first line, as on the web (Docmost 0.95; the template since 0.97): a
/// database or kanban board instead of the text (license feature `bases`), or a template's content (`templates`).
struct GetStartedRow: View {
    let offersDatabases: Bool
    let offersTemplates: Bool
    let start: (Choice) -> Void

    enum Choice {
        case database, kanban, template
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Get started with")
                .font(.footnote)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                if offersDatabases {
                    chip("Database", systemImage: "tablecells", .database)
                    chip("Kanban", systemImage: "rectangle.split.3x1", .kanban)
                }
                if offersTemplates {
                    chip("Template", systemImage: "doc.on.doc", .template)
                }
            }
        }
        .padding(.top, 8)
    }

    private func chip(_ title: LocalizedStringKey, systemImage: String, _ choice: Choice) -> some View {
        Button(title, systemImage: systemImage) { start(choice) }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityIdentifier("get-started-\(choice)")
    }
}
