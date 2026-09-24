import Foundation
import XMLCoder

struct SVNStatusDocumentDTO: Decodable {
    let target: [SVNStatusTargetDTO]
}

struct SVNStatusTargetDTO: Decodable {
    @Attribute var path: String
    let entry: [SVNStatusEntryDTO]

    enum CodingKeys: String, CodingKey { case path, entry }
}

struct SVNStatusEntryDTO: Decodable {
    @Attribute var path: String
    let workingCopyStatus: SVNWorkingCopyStatusDTO

    enum CodingKeys: String, CodingKey {
        case path
        case workingCopyStatus = "wc-status"
    }
}

struct SVNWorkingCopyStatusDTO: Decodable {
    @Attribute var item: String
    @Attribute var revision: Int?
    @Attribute var properties: String?

    enum CodingKeys: String, CodingKey {
        case item, revision
        case properties = "props"
    }
}

