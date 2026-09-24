import Foundation

struct WorkingCopy: Identifiable, Equatable, Sendable {
    let id: UUID
    let profileID: UUID
    let repositoryURL: URL
    let localURL: URL
    var displayName: String
    let createdAt: Date
    var lastOpenedAt: Date
    var lastKnownRevision: Int?
}

struct WorkingCopyLocalEntry: Identifiable, Equatable, Sendable {
    var id: String { relativePath }

    let localURL: URL
    let relativePath: String
    let isDirectory: Bool
    let byteSize: Int64?
    let modifiedAt: Date?
    let status: WorkingCopyItemStatus?
    let isPresent: Bool
}

struct WorkingCopySnapshot: Equatable, Sendable {
    let entries: [WorkingCopyLocalEntry]
    let refreshedAt: Date

    var changedItemCount: Int {
        entries.lazy.filter { $0.status != nil }.count
    }
}

enum WorkingCopyAvailability: Equatable, Sendable {
    case available
    case missing
    case invalid
    case inaccessible
}

enum WorkingCopyItemStatus: Equatable, Sendable {
    case modified
    case added
    case unversioned
    case deleted
    case missing
    case replaced
    case conflicted
    case obstructed
    case ignored
    case external
    case incomplete
    case unknown(String)

    var displayName: String {
        switch self {
        case .modified: "已修改"
        case .added: "已添加"
        case .unversioned: "未纳入版本控制"
        case .deleted: "已删除"
        case .missing: "本地丢失"
        case .replaced: "已替换"
        case .conflicted: "有冲突"
        case .obstructed: "路径异常"
        case .ignored: "已忽略"
        case .external: "外部定义"
        case .incomplete: "状态不完整"
        case let .unknown(value): "未知状态（\(value)）"
        }
    }
}
