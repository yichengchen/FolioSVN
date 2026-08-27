import Foundation
import XMLCoder

struct SVNInfoDocumentDTO: Decodable {
    let entry: SVNInfoEntryDTO
}

struct SVNInfoEntryDTO: Decodable {
    @Attribute var kind: String
    @Attribute var path: String
    @Attribute var revision: Int
    let url: String
    let size: Int64?
    let commit: SVNCommitDTO?

    enum CodingKeys: String, CodingKey {
        case kind, path, revision, url, size, commit
    }
}

struct SVNPropertiesDocumentDTO: Decodable {
    let target: [SVNPropertiesTargetDTO]?
}

struct SVNPropertiesTargetDTO: Decodable {
    @Attribute var path: String
    let property: [SVNPropertyDTO]

    enum CodingKeys: String, CodingKey { case path, property }
}

struct SVNPropertyDTO: Decodable {
    @Attribute var name: String
    let value: String

    enum CodingKeys: String, CodingKey { case name, value = "" }
}

