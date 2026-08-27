import Foundation

protocol RepositoryBrowsing: Sendable {
    func list(_ location: RepositoryLocation) async throws -> [RepositoryEntry]
}

struct RepositoryLocation: Hashable, Sendable {
    let repositoryID: UUID
    let path: RepositoryPath
}
