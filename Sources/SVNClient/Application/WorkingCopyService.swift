import Foundation

actor WorkingCopyService {
    private let store: any WorkingCopyStoring
    private let profileService: RepositoryProfileService
    private let svnClient: any SVNClient

    init(
        store: any WorkingCopyStoring,
        profileService: RepositoryProfileService,
        svnClient: any SVNClient
    ) {
        self.store = store
        self.profileService = profileService
        self.svnClient = svnClient
    }

    func list() async throws -> [WorkingCopy] {
        try await store.list()
    }

    func workingCopy(id: UUID) async throws -> WorkingCopy? {
        try await store.workingCopy(id: id)
    }

    func checkout(
        profileID: UUID,
        repositoryURL: URL,
        destinationURL: URL,
        displayName: String
    ) async throws -> WorkingCopy {
        guard let connection = try await profileService.connection(profileID: profileID) else {
            throw WorkingCopyServiceError.profileNotFound
        }
        let destination = destinationURL.standardizedFileURL.resolvingSymlinksInPath()
        try await validateDestination(destination)
        _ = try await svnClient.info(url: repositoryURL, options: connection.requestOptions)
        try Task.checkCancellation()
        let info = try await svnClient.checkout(
            url: repositoryURL,
            to: destination,
            options: connection.requestOptions
        )
        let now = Date()
        let workingCopy = WorkingCopy(
            id: UUID(),
            profileID: profileID,
            repositoryURL: info.repositoryURL,
            localURL: destination,
            displayName: displayName,
            createdAt: now,
            lastOpenedAt: now,
            lastKnownRevision: info.revision
        )
        do {
            try await store.upsert(workingCopy)
        } catch {
            // The checkout is valid user data at this point. Do not delete it when registration fails.
            throw WorkingCopyServiceError.registrationFailed(localURL: destination, underlying: error)
        }
        return workingCopy
    }

    func markOpened(_ workingCopy: WorkingCopy) async throws -> WorkingCopy {
        var updated = workingCopy
        updated.lastOpenedAt = .now
        try await store.upsert(updated)
        return updated
    }

    func status(for workingCopy: WorkingCopy) async throws -> [SVNWorkingCopyStatusEntry] {
        try await svnClient.workingCopyStatus(at: workingCopy.localURL)
    }

    func snapshot(for workingCopy: WorkingCopy) async throws -> WorkingCopySnapshot {
        let root = workingCopy.localURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else {
            throw WorkingCopyServiceError.workingCopyUnavailable
        }
        let statuses = try await svnClient.workingCopyStatus(at: workingCopy.localURL)
        try Task.checkCancellation()
        var statusByPath: [String: WorkingCopyItemStatus] = [:]
        for status in statuses {
            if let mappedStatus = status.state.domainStatus {
                statusByPath[status.relativePath] = mappedStatus
            }
        }
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: options,
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw WorkingCopyServiceError.workingCopyUnavailable
        }

        var entries: [WorkingCopyLocalEntry] = []
        var presentPaths = Set<String>()
        while let itemURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if itemURL.lastPathComponent == ".svn" {
                enumerator.skipDescendants()
                continue
            }
            let relativePath = Self.relativePath(of: itemURL, below: root)
            guard !relativePath.isEmpty else { continue }
            let values = try itemURL.resourceValues(forKeys: resourceKeys)
            let isDirectory = values.isDirectory == true
            presentPaths.insert(relativePath)
            entries.append(WorkingCopyLocalEntry(
                localURL: itemURL,
                relativePath: relativePath,
                isDirectory: isDirectory,
                byteSize: isDirectory ? nil : values.fileSize.map(Int64.init),
                modifiedAt: values.contentModificationDate,
                status: Self.effectiveStatus(for: relativePath, statuses: statusByPath),
                isPresent: true
            ))
        }
        if let enumerationError { throw enumerationError }

        for status in statuses where !status.relativePath.isEmpty && !presentPaths.contains(status.relativePath) {
            let itemURL = root.appendingPathComponent(status.relativePath)
            entries.append(WorkingCopyLocalEntry(
                localURL: itemURL,
                relativePath: status.relativePath,
                isDirectory: false,
                byteSize: nil,
                modifiedAt: nil,
                status: status.state.domainStatus,
                isPresent: false
            ))
        }
        return WorkingCopySnapshot(entries: entries, refreshedAt: .now)
    }

    func availability(of workingCopy: WorkingCopy) async -> WorkingCopyAvailability {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingCopy.localURL.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else { return .invalid }
        guard FileManager.default.isReadableFile(atPath: workingCopy.localURL.path) else { return .inaccessible }
        do {
            _ = try await svnClient.workingCopyInfo(at: workingCopy.localURL)
            return .available
        } catch {
            return .invalid
        }
    }

    func remove(id: UUID) async throws {
        try await store.delete(id: id)
    }

    func rename(id: UUID, displayName: String) async throws -> WorkingCopy {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { throw WorkingCopyServiceError.invalidDisplayName }
        guard var workingCopy = try await store.workingCopy(id: id) else {
            throw WorkingCopyServiceError.workingCopyUnavailable
        }
        workingCopy.displayName = normalizedName
        try await store.upsert(workingCopy)
        return workingCopy
    }

    func relocate(id: UUID, to localURL: URL) async throws -> WorkingCopy {
        guard let existing = try await store.workingCopy(id: id) else {
            throw WorkingCopyServiceError.workingCopyUnavailable
        }
        let candidate = localURL.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: candidate.path) else {
            throw WorkingCopyServiceError.workingCopyUnavailable
        }
        let info = try await svnClient.workingCopyInfo(at: candidate)
        guard Self.normalizedRepositoryURL(info.repositoryURL) == Self.normalizedRepositoryURL(existing.repositoryURL) else {
            throw WorkingCopyServiceError.repositoryMismatch
        }
        let candidateComponents = candidate.pathComponents
        for registered in try await store.list() where registered.id != id {
            let registeredComponents = registered.localURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            if Self.isPrefix(candidateComponents, of: registeredComponents)
                || Self.isPrefix(registeredComponents, of: candidateComponents) {
                throw WorkingCopyServiceError.overlapsRegisteredWorkingCopy
            }
        }
        let updated = WorkingCopy(
            id: existing.id,
            profileID: existing.profileID,
            repositoryURL: existing.repositoryURL,
            localURL: candidate,
            displayName: existing.displayName,
            createdAt: existing.createdAt,
            lastOpenedAt: .now,
            lastKnownRevision: info.revision
        )
        try await store.upsert(updated)
        return updated
    }

    private func validateDestination(_ destinationURL: URL) async throws {
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw SVNClientError.destinationExists
        }
        let parent = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isWritableFile(atPath: parent.path) else {
            throw WorkingCopyServiceError.destinationNotWritable
        }
        let candidate = destinationURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        for existing in try await store.list() {
            let registered = existing.localURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            if Self.isPrefix(candidate, of: registered) || Self.isPrefix(registered, of: candidate) {
                throw WorkingCopyServiceError.overlapsRegisteredWorkingCopy
            }
        }
    }

    private static func isPrefix(_ prefix: [String], of value: [String]) -> Bool {
        prefix.count <= value.count && zip(prefix, value).allSatisfy { $0.0 == $0.1 }
    }

    private static func relativePath(of itemURL: URL, below rootURL: URL) -> String {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let itemPath = itemURL.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath) else { return itemURL.lastPathComponent }
        return String(itemPath.dropFirst(rootPath.count))
    }

    private static func normalizedRepositoryURL(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func effectiveStatus(
        for relativePath: String,
        statuses: [String: WorkingCopyItemStatus]
    ) -> WorkingCopyItemStatus? {
        if let directStatus = statuses[relativePath] { return directStatus }
        var parentPath = (relativePath as NSString).deletingLastPathComponent
        while !parentPath.isEmpty {
            if let parentStatus = statuses[parentPath] {
                switch parentStatus {
                case .unversioned, .ignored, .external:
                    return parentStatus
                default:
                    return nil
                }
            }
            parentPath = (parentPath as NSString).deletingLastPathComponent
        }
        return nil
    }
}

enum WorkingCopyServiceError: LocalizedError {
    case profileNotFound
    case destinationNotWritable
    case overlapsRegisteredWorkingCopy
    case workingCopyUnavailable
    case invalidDisplayName
    case repositoryMismatch
    case registrationFailed(localURL: URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            "关联的服务器配置已经不存在"
        case .destinationNotWritable:
            "目标文件夹不存在或没有写入权限"
        case .overlapsRegisteredWorkingCopy:
            "目标位置与一个已注册的工作副本重叠"
        case .workingCopyUnavailable:
            "工作副本不存在、无法读取，或不是有效的 SVN 工作副本"
        case .invalidDisplayName:
            "工作副本名称不能为空"
        case .repositoryMismatch:
            "所选目录属于另一个 SVN 仓库位置"
        case let .registrationFailed(localURL, _):
            "检出已经完成，但无法注册工作副本。文件保留在：\(localURL.path)"
        }
    }
}
