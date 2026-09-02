import Foundation
import XMLCoder

struct SVNLogDocumentDTO: Decodable {
    let logentry: [SVNLogEntryDTO]
}

struct SVNLogEntryDTO: Decodable {
    @Attribute var revision: Int
    let author: String?
    let date: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case revision, author, date, message = "msg"
    }
}
