import Foundation
import XCTest
@testable import SVNClient

@MainActor
final class SidebarStateStoreTests: XCTestCase {
    func testExpansionAndSelectionPersistAcrossInstances() throws {
        let suiteName = "SidebarStateStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = SidebarStateStore(userDefaults: defaults, keyPrefix: "test")
        XCTAssertTrue(first.expandedKeys.contains("group.repositories"))
        first.setExpanded(true, key: "repository.profile")
        first.setExpanded(false, key: "favorites.root")
        first.setSelected(key: "directory.profile.url")

        let restored = SidebarStateStore(userDefaults: defaults, keyPrefix: "test")
        XCTAssertTrue(restored.expandedKeys.contains("repository.profile"))
        XCTAssertFalse(restored.expandedKeys.contains("favorites.root"))
        XCTAssertEqual(restored.selectedItemKey, "directory.profile.url")
    }

    func testRestoredRepositorySelectionCanReactivateTheSavedLocation() throws {
        let suiteName = "SidebarStateRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()
        defaults.set("repository.\(profileID.uuidString)", forKey: "SVNClient.Sidebar.selected")
        defaults.set(
            ["group.common", "group.repositories", "favorites.root"],
            forKey: "SVNClient.Sidebar.expanded"
        )
        let profile = RepositoryProfile(
            id: profileID,
            displayName: "公司文档",
            baseURL: try XCTUnwrap(URL(string: "https://svn.example.com/repo/")),
            username: "",
            certificatePolicy: .strict,
            createdAt: .now,
            updatedAt: .now
        )
        let viewController = SidebarViewController(userDefaults: defaults)
        _ = viewController.view
        var activatedProfileID: UUID?
        viewController.onSelectRepository = { activatedProfileID = $0 }

        viewController.setRepositoryProfiles([profile], activateRestoredSelection: true)

        XCTAssertEqual(activatedProfileID, profileID)
        viewController.clearSelection(profileID: profileID)
        let restoredState = SidebarStateStore(userDefaults: defaults)
        XCTAssertNil(restoredState.selectedItemKey)
    }
}
