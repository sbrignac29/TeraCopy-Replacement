import Foundation
import LocalAuthentication
import Security

/// Minimal Keychain wrapper for the FTP password.
///
/// Deliberately not `UserDefaults`: that writes plaintext into a plist that gets swept up
/// by backups and Time Machine. The password is low-value (a LAN credential also typed
/// into a camera) but it is still a password, so it belongs in the Keychain.
enum KeychainStore {
    private static let service = "com.spencerbrignac.vericopy.ftp"

    static func setPassword(_ password: String, account: String) {
        // Always delete first: SecItemAdd fails with errSecDuplicateItem otherwise, and
        // an update path would need a separate query anyway.
        deletePassword(account: account)
        guard !password.isEmpty, let data = password.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // The server only runs while the user is at the machine, so require unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Reads the stored password, or nil if it isn't available.
    ///
    /// A non-interactive context is essential here: it makes the read fail silently
    /// instead of raising a system authorization dialog. The app is ad-hoc signed, so its
    /// code identity changes on every rebuild and an item written by a previous build is
    /// seen as belonging to a "different" app — which would otherwise prompt. Failing
    /// quietly and asking the user to retype the password once is far better than a modal
    /// the app can get stuck behind.
    static func password(account: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            // Unreadable (missing, or owned by a previous build): drop the stale entry so
            // the next saved password is owned by THIS build and never prompts again.
            if status != errSecItemNotFound {
                deletePassword(account: account)
            }
            return nil
        }
        return value
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
