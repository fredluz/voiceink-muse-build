import Foundation
import Testing

@testable import VoiceInk

@Suite(.serialized)
struct MuseLoginCredentialsTests {
    @Test func loginCredentialWinsOverAccessToken() throws {
        let data = Data(#"{"api_key":"muse-login-credential","access_token":"oauth-access-token"}"#.utf8)

        let credential = try MuseLoginCredentials.credential(from: data)

        #expect(credential == "muse-login-credential")
    }

    @Test func accessTokenAloneIsNotAccepted() {
        let data = Data(#"{"access_token":"oauth-access-token"}"#.utf8)

        do {
            _ = try MuseLoginCredentials.credential(from: data)
            Issue.record("Expected a login without api_key to be rejected")
        } catch let error as MuseLoginCredentials.CredentialError {
            #expect(error == .missingDictationCredential)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func malformedLoginIsRejected() {
        do {
            _ = try MuseLoginCredentials.credential(from: Data("not-json".utf8))
            Issue.record("Expected malformed login data to be rejected")
        } catch let error as MuseLoginCredentials.CredentialError {
            #expect(error == .malformedLogin)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func emptyLoginCredentialIsRejected() {
        let data = Data(#"{"api_key":"  ","access_token":"oauth-access-token"}"#.utf8)

        do {
            _ = try MuseLoginCredentials.credential(from: data)
            Issue.record("Expected an empty api_key to be rejected")
        } catch let error as MuseLoginCredentials.CredentialError {
            #expect(error == .missingDictationCredential)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
