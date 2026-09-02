import Foundation

@MainActor
final class SidebarStateStore {
    private let userDefaults: UserDefaults
    private let expandedKey: String
    private let selectedKey: String

    private(set) var expandedKeys: Set<String>
    private(set) var selectedItemKey: String?

    init(userDefaults: UserDefaults = .standard, keyPrefix: String = "SVNClient.Sidebar") {
        self.userDefaults = userDefaults
        expandedKey = "\(keyPrefix).expanded"
        selectedKey = "\(keyPrefix).selected"
        if let stored = userDefaults.stringArray(forKey: expandedKey) {
            expandedKeys = Set(stored)
        } else {
            expandedKeys = ["group.common", "group.repositories", "favorites.root"]
        }
        selectedItemKey = userDefaults.string(forKey: selectedKey)
    }

    func setExpanded(_ expanded: Bool, key: String) {
        if expanded {
            expandedKeys.insert(key)
        } else {
            expandedKeys.remove(key)
        }
        userDefaults.set(expandedKeys.sorted(), forKey: expandedKey)
    }

    func setSelected(key: String?) {
        selectedItemKey = key
        userDefaults.set(key, forKey: selectedKey)
    }
}
