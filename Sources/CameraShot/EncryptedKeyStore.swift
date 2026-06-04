import CryptoKit
import CommonCrypto
import Foundation

enum AIProviderID: String, Codable, Sendable {
    case gemini
    case openAI

    var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openAI: return "OpenAI"
        }
    }
}

struct AICredentials: Codable, Equatable, Sendable {
    var geminiAPIKey: String?
    var openAIAPIKey: String?

    var hasGeminiKey: Bool { !(geminiAPIKey ?? "").isEmpty }
    var hasOpenAIKey: Bool { !(openAIAPIKey ?? "").isEmpty }

    func key(for provider: AIProviderID) -> String? {
        switch provider {
        case .gemini: return geminiAPIKey
        case .openAI: return openAIAPIKey
        }
    }

    mutating func setKey(_ key: String?, for provider: AIProviderID) {
        let cleaned = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = cleaned?.isEmpty == false ? cleaned : nil
        switch provider {
        case .gemini: geminiAPIKey = value
        case .openAI: openAIAPIKey = value
        }
    }
}

struct AICredentialStatus: Sendable {
    var hasGeminiKey: Bool
    var hasOpenAIKey: Bool
}

/// On-disk encrypted store for AI provider API keys.
///
/// File format  (~/.camerashot/api_credentials.enc):
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
        return dir.appendingPathComponent("api_credentials.enc")
    }

    static var legacyGeminiStoreURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir  = home.appendingPathComponent(".camerashot")
        return dir.appendingPathComponent("gemini_api_key.enc")
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

    /// Encrypt `credentials` with `key` and write salt + ciphertext to disk.
    /// The `salt` passed here must be the same one used to derive `key`.
    static func save(_ credentials: AICredentials, key: SymmetricKey, salt: Data) throws {
        let data   = try JSONEncoder().encode(credentials)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw StoreError.encryptionFailed }

        let fileData = salt + combined          // 16-byte salt prepended
        let url      = storeURL
        try fileData.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Compatibility helper for older call sites; stores the value as the Gemini key.
    static func save(_ plaintext: String, key: SymmetricKey, salt: Data) throws {
        try save(AICredentials(geminiAPIKey: plaintext, openAIAPIKey: nil), key: key, salt: salt)
    }

    // MARK: – Load

    /// Read the file, derive the key from `passphrase` + stored salt, decrypt.
    /// If only the legacy Gemini key exists, migrate it to the credential bundle.
    static func load(passphrase: String) throws -> (credentials: AICredentials, key: SymmetricKey, salt: Data) {
        if FileManager.default.fileExists(atPath: storeURL.path) {
            return try readCredentialsFile(at: storeURL, passphrase: passphrase)
        }

        guard FileManager.default.fileExists(atPath: legacyGeminiStoreURL.path) else {
            throw StoreError.missingFile
        }

        let legacy = try readLegacyGeminiFile(passphrase: passphrase)
        let credentials = AICredentials(geminiAPIKey: legacy.apiKey, openAIAPIKey: nil)
        try save(credentials, key: legacy.key, salt: legacy.salt)
        _ = try readCredentialsFile(at: storeURL, passphrase: passphrase)
        try? FileManager.default.removeItem(at: legacyGeminiStoreURL)
        return (credentials, legacy.key, legacy.salt)
    }

    private static func readCredentialsFile(
        at url: URL,
        passphrase: String
    ) throws -> (credentials: AICredentials, key: SymmetricKey, salt: Data) {
        let fileData = try Data(contentsOf: url)
        guard fileData.count > 44 else { throw StoreError.corruptFile }   // 16 salt + 12 nonce + 16 tag

        let salt     = Data(fileData.prefix(16))
        let combined = Data(fileData.dropFirst(16))
        let key      = deriveKey(passphrase: passphrase, salt: salt)

        do {
            let box       = try AES.GCM.SealedBox(combined: combined)
            let decrypted = try AES.GCM.open(box, using: key)
            let credentials = try JSONDecoder().decode(AICredentials.self, from: decrypted)
            return (credentials, key, salt)
        } catch is CryptoKitError {
            throw StoreError.wrongPassphrase
        } catch is DecodingError {
            throw StoreError.corruptFile
        }
    }

    private static func readLegacyGeminiFile(passphrase: String) throws -> (apiKey: String, key: SymmetricKey, salt: Data) {
        let fileData = try Data(contentsOf: legacyGeminiStoreURL)
        guard fileData.count > 44 else { throw StoreError.corruptFile }

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

    static func delete() {
        try? FileManager.default.removeItem(at: storeURL)
        try? FileManager.default.removeItem(at: legacyGeminiStoreURL)
    }

    static func fileExists() -> Bool {
        FileManager.default.fileExists(atPath: storeURL.path) ||
            FileManager.default.fileExists(atPath: legacyGeminiStoreURL.path)
    }

    // MARK: – Errors

    enum StoreError: LocalizedError {
        case encryptionFailed, corruptFile, missingFile, wrongPassphrase

        var errorDescription: String? {
            switch self {
            case .encryptionFailed: return "AES-GCM encryption failed."
            case .corruptFile:      return "The key file is corrupt or too short."
            case .missingFile:      return "No encrypted API key file exists."
            case .wrongPassphrase:  return "Wrong passphrase — decryption failed."
            }
        }
    }
}
