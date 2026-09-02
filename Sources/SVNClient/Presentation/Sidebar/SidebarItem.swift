import Foundation

@MainActor
final class SidebarItem {
    enum Kind {
        case group
        case destination
        case favoritesRoot
        case favorite(FavoriteRepositoryItem)
        case repository(UUID, URL)
        case directory(UUID, URL)
        case emptyState
        case loading
    }

    let title: String
    let subtitle: String?
    let symbolName: String
    var children: [SidebarItem]
    let kind: Kind
    var hasLoadedChildren: Bool
    var isLoadingChildren = false

    init(
        _ title: String,
        subtitle: String? = nil,
        symbolName: String = "folder",
        children: [SidebarItem] = [],
        kind: Kind = .destination,
        hasLoadedChildren: Bool = true
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.children = children
        self.kind = kind
        self.hasLoadedChildren = hasLoadedChildren
    }

    var isGroup: Bool {
        if case .group = kind { return true }
        return false
    }

    var repositoryProfileID: UUID? {
        switch kind {
        case let .repository(profileID, _), let .directory(profileID, _): return profileID
        case let .favorite(item): return item.profileID
        default: return nil
        }
    }

    var repositoryLocation: (profileID: UUID, url: URL)? {
        switch kind {
        case let .repository(profileID, url), let .directory(profileID, url): return (profileID, url)
        default: return nil
        }
    }

    var savedItem: (profileID: UUID, url: URL, name: String, kind: SavedRepositoryItemKind, revision: Int?, favoriteID: UUID?)? {
        guard case let .favorite(item) = kind else { return nil }
        return (item.profileID, item.url, item.name, item.kind, item.lastKnownRevision, item.id)
    }

    var stateKey: String? {
        switch kind {
        case .group:
            return title == "常用" ? "group.common" : "group.repositories"
        case .favoritesRoot:
            return "favorites.root"
        case let .favorite(item):
            return "favorite.\(item.id.uuidString)"
        case let .repository(profileID, _):
            return "repository.\(profileID.uuidString)"
        case let .directory(profileID, url):
            return "directory.\(profileID.uuidString).\(url.absoluteString)"
        default:
            return nil
        }
    }

    static func loadingPlaceholder() -> SidebarItem {
        SidebarItem("正在读取…", symbolName: "hourglass", kind: .loading)
    }

    static func roots(
        profiles: [RepositoryProfile],
        favorites: [FavoriteRepositoryItem] = []
    ) -> [SidebarItem] {
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let favoriteChildren = favorites.isEmpty
            ? [SidebarItem("暂无收藏", subtitle: "在文件右键菜单中添加", symbolName: "star", kind: .emptyState)]
            : favorites.map { item in
                let repositoryName = profilesByID[item.profileID]?.displayName ?? "服务器已移除"
                let subtitle = item.isAvailable ? repositoryName : "已失效 · \(repositoryName)"
                return SidebarItem(
                    item.name,
                    subtitle: subtitle,
                    symbolName: item.kind == .directory ? "folder.fill" : "doc.fill",
                    kind: .favorite(item)
                )
            }
        return [
            SidebarItem(
                "常用",
                children: [
                    SidebarItem("我的收藏", symbolName: "star", children: favoriteChildren, kind: .favoritesRoot)
                ],
                kind: .group
            ),
            SidebarItem(
                "SVN 服务器",
                children: profiles.isEmpty ? [
                    SidebarItem(
                        "尚未添加服务器",
                        subtitle: "使用下方按钮开始连接",
                        symbolName: "server.rack",
                        kind: .emptyState
                    )
                ] : profiles.map {
                    SidebarItem(
                        $0.displayName,
                        subtitle: $0.baseURL.host ?? $0.baseURL.absoluteString,
                        symbolName: "server.rack",
                        children: [loadingPlaceholder()],
                        kind: .repository($0.id, $0.startURL),
                        hasLoadedChildren: false
                    )
                },
                kind: .group
            )
        ]
    }
}
