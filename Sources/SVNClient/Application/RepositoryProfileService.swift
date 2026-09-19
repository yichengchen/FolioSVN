import Foundation

struct RepositoryConnection: Sendable {
    let profile: RepositoryProfile
    let password: String?

    var requestOptions: SVNRequestOptions {
        let normalizedPassword = password.flatMap { $0.isEmpty ? nil : $0 }
        let credentials = profile.username.isEmpty && normalizedPassword == nil
            ? nil
            : SVNCredentials(username: profile.username, password: normalizedPassword ?? "")
        return SVNRequestOptions(
            credentials: credentials,
            certificateTrustPolicy: profile.certificatePolicy.svnPolicy
        )
    }
}

extension RepositoryProfile.CertificatePolicy {
    var svnPolicy: SVNCertificateTrustPolicy {
        switch self {
        case .strict: .strict
        case .allowUnknownCertificateAuthority: .allowUnknownCertificateAuthority
        case .allowAllFailures: .allowAllFailures
        }
    }
}

actor RepositoryProfileService {
    private let profileStore: any RepositoryProfileStoring
    private let credentialStore: any CredentialStoring
    private let deletionCoordinator: RepositoryProfileDeletionCoordinator

    init(profileStore: any RepositoryProfileStoring, credentialStore: any CredentialStoring) {
        self.profileStore = profileStore
        self.credentialStore = credentialStore
        self.deletionCoordinator = RepositoryProfileDeletionCoordinator(
            profileStore: profileStore,
            credentialStore: credentialStore
        )
    }

    func list() async throws -> [RepositoryProfile] {
        try await profileStore.list()
    }

    func connection(profileID: UUID) async throws -> RepositoryConnection? {
        guard let profile = try await profileStore.profile(id: profileID) else { return nil }
        let password = try await credentialStore.password(for: profileID)
        return RepositoryConnection(profile: profile, password: password)
    }

    func save(profile: RepositoryProfile, password: String) async throws {
        let previousPassword = try await credentialStore.password(for: profile.id)
        do {
            if profile.username.isEmpty && password.isEmpty {
                try await credentialStore.removePassword(for: profile.id)
            } else {
                try await credentialStore.save(password: password, for: profile.id)
            }
            try await profileStore.upsert(profile)
        } catch {
            if let previousPassword {
                try? await credentialStore.save(password: previousPassword, for: profile.id)
            } else {
                try? await credentialStore.removePassword(for: profile.id)
            }
            throw error
        }
    }

    func delete(profileID: UUID) async throws {
        try await deletionCoordinator.delete(profileID: profileID)
    }
}
