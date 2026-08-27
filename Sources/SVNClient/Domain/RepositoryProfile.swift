import Foundation

struct RepositoryProfile: Identifiable, Codable, Equatable, Sendable {
    enum CertificatePolicy: String, Codable, CaseIterable, Sendable {
        case strict
        case allowUnknownCertificateAuthority
        case allowAllFailures
    }

    let id: UUID
    var displayName: String
    var baseURL: URL
    var username: String
    var certificatePolicy: CertificatePolicy
    var startPath: String = ""
    let createdAt: Date
    var updatedAt: Date

    var startURL: URL {
        startPath.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component), isDirectory: true)
        }
    }
}
