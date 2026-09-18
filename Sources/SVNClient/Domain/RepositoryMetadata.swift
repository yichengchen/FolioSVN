import Foundation

enum SavedRepositoryItemKind: String, Codable, Sendable {
    case file
    case directory

    init(_ kind: SVNListEntry.Kind) {
        self = kind == .directory ? .directory : .file
    }

    var svnKind: SVNListEntry.Kind {
        self == .directory ? .directory : .file
    }
}

struct FavoriteRepositoryItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileID: UUID
    var url: URL
    var name: String
    var kind: SavedRepositoryItemKind
    var lastKnownRevision: Int?
    var isAvailable: Bool
    let createdAt: Date
    var updatedAt: Date
}

struct SearchIndexEntry: Equatable, Sendable {
    let profileID: UUID
    let rootURL: URL
    let url: URL
    let name: String
    let kind: SavedRepositoryItemKind
    let size: Int64?
    let revision: Int?
    let author: String?
    let modifiedAt: Date?
}

struct RepositorySearchResults: Equatable, Sendable {
    let entries: [SearchIndexEntry]
    let indexedAt: Date?
}

struct DirectoryCacheSnapshot: Equatable, Sendable {
    static let timeToLive: TimeInterval = 25 * 60
    let entries: [SVNListEntry]
    let cachedAt: Date

    func isExpired(at date: Date = .now) -> Bool {
        date.timeIntervalSince(cachedAt) >= Self.timeToLive
    }
}
