import Foundation
import XMLCoder

struct SVNListDocumentDTO: Decodable {
    let list: SVNListDTO
}

struct SVNListDTO: Decodable {
    @Attribute var path: String
    let entry: [SVNListEntryDTO]

    enum CodingKeys: String, CodingKey { case path, entry }
}

struct SVNListEntryDTO: Decodable {
    @Attribute var kind: String
    let name: String
    let size: Int64?
    let commit: SVNCommitDTO?

    enum CodingKeys: String, CodingKey {
        case kind, name, size, commit
    }
}

struct SVNCommitDTO: Decodable {
    @Attribute var revision: Int
    let author: String?
    let date: String?

    enum CodingKeys: String, CodingKey {
        case revision, author, date
    }
}

extension SVNListEntry {
    init(dto: SVNListEntryDTO) throws {
        guard let kind = Kind(svnValue: dto.kind) else { throw SVNClientError.invalidListXML }
        self.name = dto.name
        self.kind = kind
        self.size = dto.size
        self.revision = dto.commit?.revision
        self.author = dto.commit?.author
        self.updatedAt = dto.commit?.date.flatMap(Self.parseSVNDate)
    }

    private static func parseSVNDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }
}
