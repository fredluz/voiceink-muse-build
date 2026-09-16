import Foundation
import Security

/// Accesses the credential created by the user's existing Muse login.
///
/// VoiceInk deliberately does not own this credential: it neither saves nor deletes it,
/// and only reads it after an explicit transcription request.
enum MuseLoginCredentials {
    private static let keychainService = "ai.meta.dev.credentials"
    private static let keychainAccount = "meta"

    /// Errors returned while locating or decoding the native Muse login.
    enum CredentialError: Error, LocalizedError, Equatable {
        case loginNotFound
        case keychainUnavailable
        case malformedLogin
        case missingDictationCredential

        var errorDescription: String? {
            switch self {
            case .loginNotFound:
                return String(
                    localized: "No Muse login was found. Sign in with `muse login`, then try again."
                )
            case .keychainUnavailable:
                return String(
                    localized: "Muse login is unavailable. Authorize Keychain access for VoiceInk and try again; if it was revoked or expired, sign in again with `muse login`."
                )
            case .malformedLogin:
                return String(
                    localized: "The saved Muse login is malformed or expired. Sign in again with `muse login`."
                )
            case .missingDictationCredential:
                return String(
                    localized: "The saved Muse login has no usable dictation credential. Sign in again with `muse login`; a separate developer API key is not required."
                )
            }
        }
    }

    /// Whether Muse appears configured, without reading credential bytes or prompting.
    static var isAvailable: Bool {
        keychainItemExistsWithoutPrompt()
    }

    /// Loads Muse's login-issued `api_key` on an explicit user action.
    static func load() throws -> String {
        let data = try readKeychainPayload()
        return try credential(from: data)
    }

    /// Extracts only Muse's login-issued `api_key`; `access_token` is never accepted.
    static func credential(from data: Data) throws -> String {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw CredentialError.malformedLogin
        }

        guard let apiKey = payload.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            throw CredentialError.missingDictationCredential
        }
        return apiKey
    }

    private struct Payload: Decodable {
        let apiKey: String?

        enum CodingKeys: String, CodingKey {
            case apiKey = "api_key"
        }
    }


    private static func keychainItemExistsWithoutPrompt() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private static func readKeychainPayload() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw CredentialError.loginNotFound
            }
            throw CredentialError.keychainUnavailable
        }
        guard let data = result as? Data else {
            throw CredentialError.malformedLogin
        }
        return data
    }
}
