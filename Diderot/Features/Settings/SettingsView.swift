import SwiftUI
import DocmostKit

/// Account, workspace, session and debug tools.
struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var logFile: URL?
    @State private var logError: String?

    var body: some View {
        NavigationStack {
            if let ready = session.ready {
                List {
                    Section("Account") {
                        LabeledContent("Name", value: ready.currentUser.user.displayName)
                        LabeledContent("Email", value: ready.currentUser.user.email)
                        LabeledContent("Role", value: String(localized: ready.currentUser.user.workspaceRole.title))
                    }
                    Section("Workspace") {
                        LabeledContent("Name", value: ready.currentUser.workspace.name)
                        LabeledContent("Members", value: "\(ready.currentUser.workspace.memberCount ?? 0)")
                        LabeledContent("Edition", value: ready.entitlements.tier.capitalized)
                        LabeledContent("Server", value: ready.server.url.absoluteString)
                    }
                    Section("Session") {
                        if let expiresAt = ready.tokenClaims?.expiresAt {
                            LabeledContent("Signed in until") {
                                Text(expiresAt, format: .dateTime.day().month().year())
                            }
                        }
                        if session.tokenExpiresSoon {
                            Label("Your session expires soon. You will need to sign in again.", systemImage: "clock.badge.exclamationmark")
                                .foregroundStyle(.orange)
                        }
                        NavigationLink {
                            SessionsView()
                        } label: {
                            Label("Devices", systemImage: "laptopcomputer.and.iphone")
                        }
                        NavigationLink {
                            ServersView()
                        } label: {
                            Label("Servers", systemImage: "server.rack")
                        }
                        .accessibilityIdentifier("settings-servers")
                        Button("Sign Out", role: .destructive) {
                            Task {
                                await session.signOut()
                                dismiss()
                            }
                        }
                    }
                    Section("Offline") {
                        LabeledContent("Saved content", value: cacheSizeText)
                        Button("Clear Saved Content", role: .destructive) {
                            Task {
                                await session.clearCache()
                                await updateCacheSize()
                            }
                        }
                    }
                    Section("Diagnostics") {
                        Button("Export Logs", systemImage: "square.and.arrow.up") {
                            Task {
                                do {
                                    logFile = try await LogExporter.export()
                                } catch {
                                    logError = error.localizedDescription
                                }
                            }
                        }
                        if let logError {
                            Text(logError).font(.footnote).foregroundStyle(.red)
                        }
                        LabeledContent("Version", value: Self.versionString)
                    }
                    Section("About") {
                        NavigationLink {
                            LicensesView()
                        } label: {
                            Label("Licenses", systemImage: "doc.plaintext")
                        }
                        .accessibilityIdentifier("settings-licenses")
                    }
                }
                .navigationTitle("Settings")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("settings-done")
                    }
                }
                .sheet(item: $logFile) { url in
                    ShareSheet(items: [url])
                }
                .task { await updateCacheSize() }
            }
        }
    }

    @State private var cacheSizeText = "–"

    private func updateCacheSize() async {
        guard let ready = session.ready else { return }
        let bytes = await ready.cache.totalSize()
        cacheSizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build)) · Kit \(DocmostKitInfo.version)"
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// UIKit share sheet: `ShareLink` can't share temporary files created from a button action.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
