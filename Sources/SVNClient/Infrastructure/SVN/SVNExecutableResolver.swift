import Foundation

enum SVNExecutableResolver {
    static func resolve(
        command: String = "svn",
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let fileManager = FileManager.default
        var candidates: [String] = []
#if DEBUG
        if let overridePath = environment["SVNCLIENT_SVN_PATH"] {
            candidates.append(overridePath)
        }
#endif
        if let resourcesURL = bundle.resourceURL {
            candidates.append(resourcesURL.appendingPathComponent("SVNRuntime/bin/\(command)").path)
        }
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/" + command }
        }
        candidates += [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)"
        ]

        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }
}
