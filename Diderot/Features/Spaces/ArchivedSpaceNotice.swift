import SwiftUI
import DocmostKit

/// An archived space's notice (Docmost 0.98, the web's `space-archived-notice.tsx`), in the space and above its pages:
/// who archived it and when, and "Restore Space" for its admins. The space stays editable, as the server keeps it.
struct ArchivedSpaceNotice: View {
    let space: Space
    /// For the space's admins, who may restore it.
    let restore: (() async -> Void)?
    @State private var restoring = false

    var body: some View {
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This space is archived.")
                        .font(.subheadline.weight(.semibold))
                    if let archivedAt = space.archivedAt {
                        let day = archivedAt.formatted(date: .abbreviated, time: .omitted)
                        Group {
                            if let name = space.archivedBy?.name {
                                Text("Archived by \(name) on \(day).")
                            } else {
                                Text("Archived on \(day).")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "archivebox")
            }
            Spacer(minLength: 0)
            if let restore {
                Button("Restore Space") {
                    Task {
                        restoring = true
                        await restore()
                        restoring = false
                    }
                }
                .buttonStyle(.bordered)
                .disabled(restoring)
                .accessibilityIdentifier("space-restore")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space-archived")
    }
}
