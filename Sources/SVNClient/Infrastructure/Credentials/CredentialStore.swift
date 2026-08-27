import Foundation
import KeychainAccess

protocol CredentialStoring: Sendable {
    func password(for profileID: UUID) async throws -> String?
    func save(password: String, for profileID: UUID) async throws
    func removePassword(for profileID: UUID) async throws
}

final class KeychainCredentialStore: CredentialStoring, @unchecked Sendable {
    private let keychain: Keychain

    init(service: String = "com.example.svnclient.credentials") {
        // Credentials stay local to this Mac; iCloud Keychain is deliberately disabled.
        keychain = Keychain(service: service).synchronizable(false)
    }

    func password(for profileID: UUID) async throws -> String? {
        try keychain.get(profileID.uuidString)
    }

    func save(password: String, for profileID: UUID) async throws {
        try keychain.set(password, key: profileID.uuidString)
    }

    func removePassword(for profileID: UUID) async throws {
        try keychain.remove(profileID.uuidString)
    }
}
