import Foundation

/// Coordinates two independent stores. This cannot be an atomic transaction:
/// if SQLite deletion fails after Keychain removal, the original password is restored when possible.
actor RepositoryProfileDeletionCoordinator {
    private let profileStore: any RepositoryProfileStoring
    private let credentialStore: any CredentialStoring

    init(profileStore: any RepositoryProfileStoring, credentialStore: any CredentialStoring) {
        self.profileStore = profileStore
        self.credentialStore = credentialStore
    }

    func delete(profileID: UUID) async throws {
        let previousPassword = try await credentialStore.password(for: profileID)
        try await credentialStore.removePassword(for: profileID)
        do {
            try await profileStore.delete(id: profileID)
        } catch {
            guard let previousPassword else {
                throw RepositoryProfileDeletionError.databaseDeletionFailed(profileID: profileID, credentialRestored: true)
            }
            do {
                try await credentialStore.save(password: previousPassword, for: profileID)
                throw RepositoryProfileDeletionError.databaseDeletionFailed(profileID: profileID, credentialRestored: true)
            } catch is RepositoryProfileDeletionError {
                throw RepositoryProfileDeletionError.databaseDeletionFailed(profileID: profileID, credentialRestored: true)
            } catch {
                throw RepositoryProfileDeletionError.databaseDeletionFailed(profileID: profileID, credentialRestored: false)
            }
        }
    }
}

enum RepositoryProfileDeletionError: Error, Equatable, Sendable {
    case databaseDeletionFailed(profileID: UUID, credentialRestored: Bool)
}
