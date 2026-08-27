import Foundation
import XCTest
@testable import SVNClient

final class RepositoryProfileStoreTests: XCTestCase {
    func testInMemoryStorePersistsNonSensitiveProfileFields() async throws {
        let store = try RepositoryProfileStore(inMemory: ())
        let profile = makeProfile(displayName: "公司文档")

        try await store.upsert(profile)

        let loadedProfile = try await store.profile(id: profile.id)
        let profiles = try await store.list()
        XCTAssertEqual(loadedProfile, profile)
        XCTAssertEqual(profiles, [profile])
    }

    func testUpsertReplacesProfileAndDeleteRemovesIt() async throws {
        let store = try RepositoryProfileStore(inMemory: ())
        var profile = makeProfile(displayName: "旧名称")
        try await store.upsert(profile)
        profile.displayName = "新名称"
        profile.updatedAt = profile.updatedAt.addingTimeInterval(60)
        try await store.upsert(profile)

        let updatedProfile = try await store.profile(id: profile.id)
        XCTAssertEqual(updatedProfile?.displayName, "新名称")
        try await store.delete(id: profile.id)
        let deletedProfile = try await store.profile(id: profile.id)
        XCTAssertNil(deletedProfile)
    }

    func testDeletionRestoresPasswordWhenDatabaseDeletionFails() async throws {
        let profile = makeProfile(displayName: "公司文档")
        let profiles = FailingDeleteProfileStore(profile: profile)
        let credentials = InMemoryCredentialStore(passwords: [profile.id: "secret"])
        let coordinator = RepositoryProfileDeletionCoordinator(profileStore: profiles, credentialStore: credentials)

        do {
            try await coordinator.delete(profileID: profile.id)
            XCTFail("Expected delete failure")
        } catch let error as RepositoryProfileDeletionError {
            XCTAssertEqual(error, .databaseDeletionFailed(profileID: profile.id, credentialRestored: true))
        }
        let restoredPassword = await credentials.passwordValue(for: profile.id)
        XCTAssertEqual(restoredPassword, "secret")
    }

    private func makeProfile(displayName: String) -> RepositoryProfile {
        RepositoryProfile(
            id: UUID(),
            displayName: displayName,
            baseURL: URL(string: "https://svn.example.com/repos/company")!,
            username: "zhangsan",
            certificatePolicy: .strict,
            startPath: "技术部/共享资料",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

private final class FailingDeleteProfileStore: RepositoryProfileStoring, @unchecked Sendable {
    private let storedProfile: RepositoryProfile

    init(profile: RepositoryProfile) { storedProfile = profile }
    func list() async throws -> [RepositoryProfile] { [storedProfile] }
    func profile(id: UUID) async throws -> RepositoryProfile? { id == storedProfile.id ? storedProfile : nil }
    func upsert(_ profile: RepositoryProfile) async throws {}
    func delete(id: UUID) async throws { throw TestFailure.databaseUnavailable }
}

private actor InMemoryCredentialStore: CredentialStoring {
    private var passwords: [UUID: String]

    init(passwords: [UUID: String]) { self.passwords = passwords }
    func password(for profileID: UUID) async throws -> String? { passwords[profileID] }
    func save(password: String, for profileID: UUID) async throws { passwords[profileID] = password }
    func removePassword(for profileID: UUID) async throws { passwords.removeValue(forKey: profileID) }
    func passwordValue(for profileID: UUID) -> String? { passwords[profileID] }
}

private enum TestFailure: Error { case databaseUnavailable }
