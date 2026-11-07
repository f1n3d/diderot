import Foundation
import DocmostKit

/// The note being written in "Append Note", kept on the device until it is appended or cancelled (code review V49: it
/// lived only in its sheet, so a crash or a server switch lost it). It goes into the session's unsent changes: per
/// server and user, and kept out of backups.
@MainActor
final class NoteDraft {
    private nonisolated struct Kept: Codable, Sendable {
        let text: String
    }

    private let store: UnsentStore
    private let key: String
    private let clock: any Clock<Duration>
    private var saving: Task<Void, Never>?
    /// What the store holds, as far as this draft knows ("" for nothing): the note just restored isn't written again.
    private var written: String?

    /// `clock`: what the wait for more typing runs on; tests move a clock of their own (`TestClock`).
    init(pageId: String, store: UnsentStore, clock: any Clock<Duration> = ContinuousClock()) {
        self.store = store
        self.key = CacheKey.noteDraft(pageId)
        self.clock = clock
    }

    /// The note kept from before, nil without one.
    func kept() async -> String? {
        do {
            let text = try await store.read(Kept.self, key: key)?.text
            written = text ?? ""
            return text
        } catch {
            AppLog.session.error("Kept note unreadable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Keeps `text` once typing pauses for half a second; an empty one drops the note kept. The wait goes on without the
    /// sheet: a server switch closes it.
    func keep(_ text: String) {
        saving?.cancel()
        guard text != written else { return }
        saving = Task {
            do {
                try await clock.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            await write(text)
        }
    }

    /// Keeps `text` at once: the app goes to the background, where iOS may end it before a wait for more typing ends.
    func keepNow(_ text: String) async {
        saving?.cancel()
        await saving?.value
        guard text != written else { return }
        await write(text)
    }

    /// Waits until the last `keep` has written its text, or given up.
    func settled() async {
        await saving?.value
    }

    /// Drops the note kept: it was appended, or cancelled. A keep still waiting goes first, so it can't bring it back.
    func forget() async {
        saving?.cancel()
        await saving?.value
        do {
            try await store.remove(key: key)
            written = ""
        } catch {
            AppLog.session.error("Kept note not dropped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func write(_ text: String) async {
        do {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await store.remove(key: key)
                written = ""
            } else {
                try await store.write(Kept(text: text), key: key)
                written = text
            }
        } catch {
            AppLog.session.error("Note not kept: \(error.localizedDescription, privacy: .public)")
        }
    }
}
