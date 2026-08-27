import Foundation

@MainActor
final class SidebarItem {
    enum Kind {
        case group
        case destination
        case favoritesRoot
        case recentsRoot
        case favorite(FavoriteRepositoryItem)
        case recent(RecentRepositoryItem)
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
        case let .recent(item): return item.profileID
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
        switch kind {
        case let .favorite(item):
            return (item.profileID, item.url, item.name, item.kind, item.lastKnownRevision, item.id)
        case let .recent(item):
            return (item.profileID, item.url, item.name, item.kind, item.lastKnownRevision, nil)
        default:
            return nil
        }
    }

    static func loadingPlaceholder() -> SidebarItem {
        SidebarItem("正在读取…", symbolName: "hourglass", kind: .loading)
    }

    static func roots(
        profiles: [RepositoryProfile],
        favorites: [FavoriteRepositoryItem] = [],
        recentItems: [RecentRepositoryItem] = []
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
        let recentChildren = recentItems.isEmpty
            ? [SidebarItem("暂无最近访问", symbolName: "clock", kind: .emptyState)]
            : recentItems.map { item in
                SidebarItem(
                    item.name,
                    subtitle: profilesByID[item.profileID]?.displayName ?? "服务器已移除",
                    symbolName: item.kind == .directory ? "folder" : "doc",
                    kind: .recent(item)
                )
            }
        return [
            SidebarItem(
                "常用",
                children: [
                    SidebarItem("我的收藏", symbolName: "star", children: favoriteChildren, kind: .favoritesRoot),
                    SidebarItem("最近访问", symbolName: "clock", children: recentChildren, kind: .recentsRoot)
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
