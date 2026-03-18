import CryptoKit
import CommonCrypto
import Foundation

/// On-disk encrypted store for the Anthropic API key.
///
/// File format  (~/.camerashot/api_key.enc):
///   salt (16 bytes) | AES-GCM combined blob (nonce 12 + ciphertext + tag 16)
///
/// Key derivation:
///   PBKDF2-HMAC-SHA256, 200 000 iterations, 32-byte output.
///   The salt is randomly generated on first save and stored in the file header.
///   The same passphrase + same salt always produces the same 256-bit AES key.
enum EncryptedKeyStore {

    // MARK: – File location

    static var storeURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir  = home.appendingPathComponent(".camerashot")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("api_key.enc")
    }

    static var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return storeURL.path.replacingOccurrences(of: home, with: "~")
    }

    // MARK: – Key derivation  (PBKDF2-SHA256)

    static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        var derived  = [UInt8](repeating: 0, count: 32)
        let passBytes = Array(passphrase.utf8)
        let saltBytes = Array(salt)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passBytes, passBytes.count,
            saltBytes, saltBytes.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            200_000,
            &derived, 32
        )
        return SymmetricKey(data: Data(derived))
    }

    static func generateSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        return Data(bytes)
    }

    // MARK: – Save

    /// Encrypt `plaintext` with `key` and write salt + ciphertext to disk.
    /// The `salt` passed here must be the same one used to derive `key`.
    static func save(_ plaintext: String, key: SymmetricKey, salt: Data) throws {
        let data   = Data(plaintext.utf8)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw StoreError.encryptionFailed }

        let fileData = salt + combined          // 16-byte salt prepended
        let url      = storeURL
        try fileData.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: – Load

    /// Read the file, derive the key from `passphrase` + stored salt, decrypt.
    /// Returns (decryptedAPIKey, derivedKey, storedSalt) on success.
    static func load(passphrase: String) throws -> (apiKey: String, key: SymmetricKey, salt: Data) {
        let fileData = try Data(contentsOf: storeURL)
        guard fileData.count > 44 else { throw StoreError.corruptFile }   // 16 salt + 12 nonce + 16 tag

        let salt     = Data(fileData.prefix(16))
        let combined = Data(fileData.dropFirst(16))
        let key      = deriveKey(passphrase: passphrase, salt: salt)

        do {
            let box       = try AES.GCM.SealedBox(combined: combined)
            let decrypted = try AES.GCM.open(box, using: key)
            guard let str = String(data: decrypted, encoding: .utf8) else { throw StoreError.corruptFile }
            return (str, key, salt)
        } catch is CryptoKitError {
            throw StoreError.wrongPassphrase
        }
    }

    // MARK: – Delete / Existence

    static func delete() { try? FileManager.default.removeItem(at: storeURL) }

    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: storeURL.path)
    }

    // MARK: – Errors

    enum StoreError: LocalizedError {
        case encryptionFailed, corruptFile, wrongPassphrase

        var errorDescription: String? {
            switch self {
            case .encryptionFailed: return "AES-GCM encryption failed."
            case .corruptFile:      return "The key file is corrupt or too short."
            case .wrongPassphrase:  return "Wrong passphrase — decryption failed."
            }
        }
    }
}
