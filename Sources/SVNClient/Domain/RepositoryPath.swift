import Foundation

struct RepositoryPath: Hashable, Codable, Sendable {
    let value: String

    init(_ value: String) {
        var normalizedComponents: [Substring] = []
        for component in value.split(separator: "/") {
            switch component {
            case "", ".":
                continue
            case "..":
                if !normalizedComponents.isEmpty {
                    normalizedComponents.removeLast()
                }
            default:
                normalizedComponents.append(component)
            }
        }
        self.value = normalizedComponents.joined(separator: "/")
    }
}
