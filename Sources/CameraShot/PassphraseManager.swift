import IOKit
import Foundation

/// Returns the machine-bound passphrase used to derive the AES-256-GCM session key.
///
/// Formula (hardcoded, visible in source):
///   "this is the passkey <IOPlatformUUID>"
///
/// The IOPlatformUUID is the hardware board identifier — unique per machine.
/// An encrypted file copied to a different machine cannot be decrypted because
/// the UUID (and therefore the derived AES key) will differ.
enum PassphraseManager {

    static func machineUUID() -> String {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(service) }
        guard service != IO_OBJECT_NULL else { return "unknown-uuid" }
        let cfKey = "IOPlatformUUID" as CFString
        guard let value = IORegistryEntryCreateCFProperty(
            service, cfKey, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return "unknown-uuid" }
        return value
    }

    static var activePassphrase: String {
        "this is the passkey \(machineUUID())"
    }
}
