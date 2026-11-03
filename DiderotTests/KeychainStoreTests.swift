import Foundation
import Security
import Testing
import DocmostKit

/// The sign-ins in the Keychain (`KeychainStore`): readable after the first unlock and on this device only, so they go
/// neither to iCloud Keychain nor with a backup to another device.
struct KeychainStoreTests {
    private let store = KeychainStore()

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.github.f1n3d.diderot",
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func attributes(account: String) -> [String: Any]? {
        var query = query(account: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    @Test func aSecretStaysOnThisDevice() throws {
        let account = "keychain-test-\(UUID().uuidString)"
        defer { try? store.delete(account: account) }
        try store.save(Data("geheim".utf8), account: account)
        let saved = try #require(attributes(account: account))
        #expect(saved[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((saved[kSecAttrSynchronizable as String] as? Bool) != true)
        #expect(try store.load(account: account) == Data("geheim".utf8))
    }

    /// An item saved with another protection (an older version) gets this one with its next save.
    @Test func aSaveProtectsAnOlderItem() throws {
        let account = "keychain-test-\(UUID().uuidString)"
        defer { try? store.delete(account: account) }
        var older = query(account: account)
        older[kSecValueData as String] = Data("alt".utf8)
        older[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        #expect(SecItemAdd(older as CFDictionary, nil) == errSecSuccess)
        try store.save(Data("neu".utf8), account: account)
        #expect(attributes(account: account)?[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(try store.load(account: account) == Data("neu".utf8))
    }
}
