import Foundation

enum EntryKind: String, Codable, Sendable {
    case file
    case directory
}

struct RepositoryEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let repositoryID: UUID
    let path: RepositoryPath
    let kind: EntryKind
    let size: Int64?
}
