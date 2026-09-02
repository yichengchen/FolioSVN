import Foundation

enum AppBrand {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Folio SVN"
    }
}
