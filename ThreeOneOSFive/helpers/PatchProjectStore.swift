import CryptoKit
import Foundation

private enum VesperDashDigest {
    static func hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PatchStoreAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
    var messageArgument: String?

    init(titleKey: String, messageKey: String, messageArgument: String? = nil) {
        self.titleKey = titleKey
        self.messageKey = messageKey
        self.messageArgument = messageArgument
    }

    func message(language: AppLanguage) -> String {
        if let messageArgument {
            return language.text(messageKey, messageArgument)
        }
        return language.text(messageKey)
    }
}

@MainActor
final class PatchProjectStore: ObservableObject {
    private static let initialSyncCompletedKey = "vesperdash.initialSyncCompleted.v4"
    private static let remoteEntriesKey = "vesperdash.remoteEntries.v1"
    private static let remoteCategoriesKey = "vesperdash.remoteCategories.v1"
    private static let remoteImagesKey = "vesperdash.remoteImages.v1"
    private static let remoteStatusesKey = "vesperdash.remoteStatuses.v1"
    private static let remoteOrdersKey = "vesperdash.remoteOrders.v1"
    private static let remoteBundlesKey = "vesperdash.remoteBundles.v1"
    @Published private(set) var items: [PatchLibraryItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var hasCompletedInitialSync = false
    @Published private(set) var isRemoteDisabled = false
    @Published private(set) var remoteSyncMessage = "REMOTE DATA: WAITING"
    @Published private(set) var remoteCategories: [String: String] = [:]
    @Published private(set) var remoteImageURLs: [String: URL] = [:]
    @Published private(set) var remoteStatusTexts: [String: String] = [:]
    @Published private(set) var remoteOrders: [String: Int] = [:]
    @Published private(set) var remoteEntries: [RemotePatch] = []
    @Published private(set) var remoteBundleIDs: [String: String] = [:]
    @Published var passwordRequest: PatchPasswordRequest?
    @Published var alert: PatchStoreAlert?
    @Published var unlockErrorKey: String?

    private struct PendingUnlock {
        let data: Data
        let summary: PatchPackageSummary
        let existingURL: URL?
    }

    private var pendingUnlock: PendingUnlock?

    init() {
        PatchProjectLibrary.installBundledPackagesIfNeeded()
        reload()
        hasCompletedInitialSync = UserDefaults.standard.bool(forKey: Self.initialSyncCompletedKey)
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.remoteEntriesKey),
           let entries = try? JSONDecoder().decode([RemotePatch].self, from: data) {
            remoteEntries = entries
        }
        remoteCategories = defaults.dictionary(forKey: Self.remoteCategoriesKey) as? [String: String] ?? [:]
        remoteStatusTexts = defaults.dictionary(forKey: Self.remoteStatusesKey) as? [String: String] ?? [:]
        remoteBundleIDs = defaults.dictionary(forKey: Self.remoteBundlesKey) as? [String: String] ?? [:]
        if let savedOrders = defaults.dictionary(forKey: Self.remoteOrdersKey) as? [String: NSNumber] {
            remoteOrders = savedOrders.mapValues(\.intValue)
        }
        if let savedImages = defaults.dictionary(forKey: Self.remoteImagesKey) as? [String: String] {
            remoteImageURLs = savedImages.compactMapValues(URL.init(string:))
        }
    }

    func reload() {
        items = PatchProjectLibrary.load()
    }

    /// Reconcile bundled resources with Application Support after an app
    /// upgrade, then rebuild the in-memory package list.
    func refreshBundledPackages() {
        PatchProjectLibrary.installBundledPackagesIfNeeded()
        reload()
    }

    /// Pull enabled, non-paused packages from VesperDash and install them
    /// locally. The package is still decoded by PatchPackageCodec, and the
    /// server-provided digest is checked before anything is persisted.
    func syncVesperDash(showCompletionAlert: Bool = true) {
        guard !isBusy else { return }
        isBusy = true
        remoteBundleIDs = [:]
        remoteSyncMessage = "REMOTE DATA: CHECKING…"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let manifest = try await VesperDashRemoteSync.fetchManifest()
                await self?.applyRemoteState(paused: manifest.global_paused)
                await self?.applyRemoteEntries(manifest.all_patches ?? manifest.patches)
                guard !manifest.global_paused else {
                    await self?.finishRemoteSync(showCompletionAlert: showCompletionAlert, patchCount: 0)
                    return
                }
                var metadataByDigest: [String: (category: String, imageURL: URL?, statusText: String, sortOrder: Int)] = [:]
                for remote in manifest.patches {
                    let digest = remote.sha256.lowercased()
                    if metadataByDigest[digest] == nil {
                        metadataByDigest[digest] = (
                            remote.normalizedCategory,
                            VesperDashRemoteSync.validImageURL(for: remote),
                            remote.status_text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            remote.normalizedOrder
                        )
                    }
                }
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                for remote in manifest.patches {
                    do {
                        if let localURL = await self?.existingPackageURL(matchingDigest: remote.sha256) {
                            await self?.recordRemoteBundleID(
                                remoteBundleID: remote.bundle_id,
                                filename: localURL.lastPathComponent
                            )
                            continue
                        }
                        guard let url = VesperDashRemoteSync.validDownloadURL(for: remote) else { continue }
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 60
                        let (data, response) = try await session.data(for: request)
                        guard let http = response as? HTTPURLResponse,
                              (200..<300).contains(http.statusCode),
                              data.starts(with: Data("3105PATCH\0".utf8)),
                              VesperDashDigest.hex(data) == remote.sha256.lowercased() else { continue }
                        let summary = try PatchPackageCodec.inspect(data)
                        let decoded = try PatchPackageCodec.decode(data, password: "XRE")
                        let existingURL = await self?.existingPackageURL(for: summary.packageID)
                        try PatchKeyStore.store(decoded.contentKey, for: summary)
                        try PatchProjectLibrary.installImportedPackage(
                            data: data,
                            decoded: decoded,
                            summary: summary,
                            existingURL: existingURL
                        )
                        let localFilename = existingURL?.lastPathComponent
                            ?? PatchProjectLibrary.sanitizedPackageFilename(decoded.project.name)
                        await self?.recordRemoteBundleID(remoteBundleID: remote.bundle_id, filename: localFilename)
                    } catch {
                        continue
                    }
                }
                await self?.reconcileRemotePackages(metadataByDigest: metadataByDigest)
                await self?.finishRemoteSync(showCompletionAlert: showCompletionAlert, patchCount: manifest.patches.count)
            } catch {
                await self?.failRemoteSync()
            }
        }
    }

    private func finishRemoteSync(showCompletionAlert: Bool = true, patchCount: Int = 0) {
        reload()
        isBusy = false
        hasCompletedInitialSync = true
        UserDefaults.standard.set(true, forKey: Self.initialSyncCompletedKey)
        remoteSyncMessage = "REMOTE DATA: UPDATED • \(patchCount) PATCH\(patchCount == 1 ? "" : "ES")"
        if showCompletionAlert {
            alert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.imported_message")
        }
    }

    private func applyRemoteState(paused: Bool) {
        isRemoteDisabled = paused
    }

    private func applyRemoteEntries(_ entries: [RemotePatch]) {
        var seenDigests = Set<String>()
        remoteEntries = entries.filter { entry in
            seenDigests.insert(entry.sha256.lowercased()).inserted
        }
        if let data = try? JSONEncoder().encode(remoteEntries) {
            UserDefaults.standard.set(data, forKey: Self.remoteEntriesKey)
        }
    }

    func remoteEntries(category: String, bundleID: String) -> [RemotePatch] {
        remoteEntries
            .filter { $0.enabled && !$0.paused && $0.normalizedCategory == category && $0.bundle_id == bundleID }
            .sorted {
                if $0.normalizedOrder != $1.normalizedOrder { return $0.normalizedOrder < $1.normalizedOrder }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func localFilename(for remote: RemotePatch) -> String? {
        items.first { item in
            guard let data = try? PatchProjectLibrary.readPackage(at: item.packageURL) else { return false }
            return VesperDashDigest.hex(data).caseInsensitiveCompare(remote.sha256) == .orderedSame
        }?.packageURL.lastPathComponent
    }

    func remoteCategory(for item: PatchLibraryItem) -> String {
        remoteCategories[item.packageURL.standardizedFileURL.path] ?? "aim"
    }

    func hasRemoteMetadata(for item: PatchLibraryItem) -> Bool {
        remoteCategories[item.packageURL.standardizedFileURL.path] != nil
    }

    func remoteImageURL(for item: PatchLibraryItem) -> URL? {
        remoteImageURLs[item.packageURL.standardizedFileURL.path]
    }

    func remoteStatusText(for item: PatchLibraryItem) -> String {
        let value = remoteStatusTexts[item.packageURL.standardizedFileURL.path] ?? ""
        return value.isEmpty ? "NO STATUS" : value
    }

    func remoteOrder(for item: PatchLibraryItem) -> Int {
        remoteOrders[item.packageURL.standardizedFileURL.path] ?? 1000
    }

    private func reconcileRemotePackages(metadataByDigest: [String: (category: String, imageURL: URL?, statusText: String, sortOrder: Int)]) {
        var categories: [String: String] = [:]
        var imageURLs: [String: URL] = [:]
        var statusTexts: [String: String] = [:]
        var orders: [String: Int] = [:]
        var seenDigests = Set<String>()
        for item in PatchProjectLibrary.load() {
            guard let data = try? PatchProjectLibrary.readPackage(at: item.packageURL) else { continue }
            let digest = VesperDashDigest.hex(data)
            if let metadata = metadataByDigest[digest], seenDigests.insert(digest).inserted {
                let path = item.packageURL.standardizedFileURL.path
                categories[path] = metadata.category
                if let imageURL = metadata.imageURL {
                    imageURLs[path] = imageURL
                }
                statusTexts[path] = metadata.statusText
                orders[path] = metadata.sortOrder
            } else {
                try? PatchProjectLibrary.delete(item)
            }
        }
        remoteCategories = categories
        remoteImageURLs = imageURLs
        remoteStatusTexts = statusTexts
        remoteOrders = orders
        let defaults = UserDefaults.standard
        defaults.set(categories, forKey: Self.remoteCategoriesKey)
        defaults.set(statusTexts, forKey: Self.remoteStatusesKey)
        defaults.set(orders, forKey: Self.remoteOrdersKey)
        defaults.set(imageURLs.mapValues(\.absoluteString), forKey: Self.remoteImagesKey)
        defaults.set(remoteBundleIDs, forKey: Self.remoteBundlesKey)
    }

    private func recordRemoteBundleID(remoteBundleID: String, filename: String) {
        remoteBundleIDs[filename] = remoteBundleID
    }

    func remoteBundleID(for item: PatchLibraryItem) -> String? {
        if let bundleID = remoteBundleIDs[item.packageURL.lastPathComponent] {
            return bundleID
        }
        guard let data = try? PatchProjectLibrary.readPackage(at: item.packageURL) else {
            return nil
        }
        let digest = VesperDashDigest.hex(data)
        return remoteEntries.first { $0.sha256.caseInsensitiveCompare(digest) == .orderedSame }?.bundle_id
    }

    private func failRemoteSync() {
        isBusy = false
        remoteSyncMessage = "REMOTE DATA: CHECK FAILED • RETRYING"
        alert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.remote_import")
    }

    func create(project: PatchProject, password: String?) {
        runOperation(successMessageKey: "patch.created_message") {
            let encoded = try PatchPackageCodec.encodeNew(project: project, password: password)
            let summary = try PatchPackageCodec.inspect(encoded.data)
            let workspace = try PatchWorkspaceService.createWorkspace(for: project)
            do {
                if summary.isPasswordProtected {
                    try PatchKeyStore.store(encoded.contentKey, for: summary)
                }
                _ = try PatchProjectLibrary.save(data: encoded.data, projectName: project.name)
            } catch {
                try? FileManager.default.removeItem(at: workspace)
                try? PatchKeyStore.delete(for: summary)
                throw error
            }
        }
    }

    func update(project: PatchProject) {
        guard let item = items.first(where: { $0.id == project.id }),
              let contentKey = item.contentKey else {
            present(.invalidProject)
            return
        }
        runOperation(successMessageKey: "patch.updated_message") {
            let original = try PatchProjectLibrary.readPackage(at: item.packageURL)
            let updated = try PatchPackageCodec.update(
                original,
                project: project,
                contentKey: contentKey
            )
            _ = try PatchProjectLibrary.save(
                data: updated,
                projectName: project.name,
                existingURL: item.packageURL
            )
        }
    }

    func importPackage(at sourceURL: URL) {
        guard !isBusy else { return }
        isBusy = true
        let hasAccess = sourceURL.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) { [weak self] in
            defer {
                if hasAccess { sourceURL.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try PatchProjectLibrary.readPackage(at: sourceURL)
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = await self?.existingPackageURL(for: summary.packageID)
                if let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL
                ) {
                    await self?.requestPassword(pending: pending)
                } else {
                    await self?.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.unsupportedFormat)
            }
        }
    }

    func importPackage(from source: PatchImportSource) {
        switch source {
        case .file(let url):
            importPackage(at: url)
        case .remote(let url):
            importPackage(fromRemoteURL: url)
        case .invalid:
            present(.invalidImportLink)
        }
    }

    private func importPackage(fromRemoteURL remoteURL: URL) {
        guard !isBusy,
              PatchImportRoute.validatedRemoteURL(remoteURL) != nil else {
            if !isBusy { present(.invalidImportLink) }
            return
        }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }

                let (temporaryURL, response) = try await session.download(from: remoteURL)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let finalURL = response.url,
                      PatchImportRoute.validatedRemoteURL(finalURL) != nil else {
                    throw PatchPackageError.remoteImportFailed
                }

                let data = try PatchProjectLibrary.readPackage(at: temporaryURL)
                let summary = try PatchPackageCodec.inspect(data)
                let existingURL = await self?.existingPackageURL(for: summary.packageID)
                if let pending = try Self.persistImportedPackage(
                    data: data,
                    summary: summary,
                    existingURL: existingURL
                ) {
                    await self?.requestPassword(pending: pending)
                } else {
                    await self?.finishOperation(successMessageKey: "patch.imported_message")
                }
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.remoteImportFailed)
            }
        }
    }

    func requestUnlock(for item: PatchLibraryItem) {
        guard item.isLocked, !isBusy else { return }
        do {
            let data = try PatchProjectLibrary.readPackage(at: item.packageURL)
            pendingUnlock = PendingUnlock(data: data, summary: item.summary, existingURL: item.packageURL)
            passwordRequest = PatchPasswordRequest(summary: item.summary)
        } catch let error as PatchPackageError {
            present(error)
        } catch {
            present(.unsupportedFormat)
        }
    }

    func unlock(password: String) {
        guard let pending = pendingUnlock, !isBusy else { return }
        isBusy = true
        unlockErrorKey = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let decoded = try PatchPackageCodec.decode(pending.data, password: password)
                try PatchKeyStore.store(decoded.contentKey, for: pending.summary)
                do {
                    try PatchProjectLibrary.installImportedPackage(
                        data: pending.data,
                        decoded: decoded,
                        summary: pending.summary,
                        existingURL: pending.existingURL
                    )
                } catch {
                    try? PatchKeyStore.delete(for: pending.summary)
                    throw error
                }
                await self?.clearPendingUnlock()
                await self?.finishOperation(successMessageKey: "patch.unlocked_message")
            } catch let error as PatchPackageError {
                await self?.failUnlock(error)
            } catch {
                await self?.failUnlock(.invalidPasswordOrCorruptedPackage)
            }
        }
    }

    func cancelUnlock() {
        clearPendingUnlock()
        isBusy = false
    }

    func clearUnlockError() {
        unlockErrorKey = nil
    }

    func delete(_ item: PatchLibraryItem) {
        do {
            try PatchProjectLibrary.delete(item)
            reload()
        } catch {
            present(.invalidProject)
        }
    }

    func synchronizeWorkspace(projectID: UUID, reportsSuccess: Bool = false) {
        guard let item = items.first(where: { $0.id == projectID }),
              item.summary.schemaVersion >= 2,
              !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                _ = try PatchProjectLibrary.synchronizeWorkspace(item: item)
                await self?.finishWorkspaceSynchronization(reportsSuccess: reportsSuccess)
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.invalidProject)
            }
        }
    }

    private func finishWorkspaceSynchronization(reportsSuccess: Bool) {
        reload()
        isBusy = false
        if reportsSuccess {
            alert = PatchStoreAlert(
                titleKey: "common.done",
                messageKey: "patch.workspace_synced_message"
            )
        }
    }

    private func runOperation(
        successMessageKey: String,
        operation: @escaping () throws -> Void
    ) {
        guard !isBusy else { return }
        isBusy = true
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try operation()
                await self?.finishOperation(successMessageKey: successMessageKey)
            } catch let error as PatchPackageError {
                await self?.failOperation(error)
            } catch {
                await self?.failOperation(.invalidProject)
            }
        }
    }

    private func requestPassword(pending: PendingUnlock) {
        pendingUnlock = pending
        passwordRequest = PatchPasswordRequest(summary: pending.summary)
        isBusy = false
    }

    private func existingPackageURL(for packageID: UUID) -> URL? {
        items.first(where: { $0.id == packageID })?.packageURL
    }

    private func existingPackageURL(matchingDigest digest: String) -> URL? {
        items.first { item in
            guard let data = try? PatchProjectLibrary.readPackage(at: item.packageURL) else { return false }
            return VesperDashDigest.hex(data).caseInsensitiveCompare(digest) == .orderedSame
        }?.packageURL
    }

    private nonisolated static func persistImportedPackage(
        data: Data,
        summary: PatchPackageSummary,
        existingURL: URL?
    ) throws -> PendingUnlock? {
        if let key = try PatchKeyStore.load(for: summary) {
            let decoded = try PatchPackageCodec.decode(data, contentKey: key)
            try PatchProjectLibrary.installImportedPackage(
                data: data,
                decoded: decoded,
                summary: summary,
                existingURL: existingURL
            )
            return nil
        }
        if summary.isPasswordProtected {
            return PendingUnlock(data: data, summary: summary, existingURL: existingURL)
        }
        let decoded = try PatchPackageCodec.decode(data, password: nil)
        try PatchProjectLibrary.installImportedPackage(
            data: data,
            decoded: decoded,
            summary: summary,
            existingURL: existingURL
        )
        return nil
    }

    private func clearPendingUnlock() {
        pendingUnlock = nil
        passwordRequest = nil
        unlockErrorKey = nil
    }

    private func finishOperation(successMessageKey: String) {
        reload()
        isBusy = false
        alert = PatchStoreAlert(titleKey: "common.done", messageKey: successMessageKey)
    }

    private func failOperation(_ error: PatchPackageError) {
        isBusy = false
        present(error)
    }

    private func failUnlock(_ error: PatchPackageError) {
        isBusy = false
        // Keep the password sheet open so the user can retry.
        // Presenting an alert while dismissing the sheet swallows the message.
        if case .invalidPasswordOrCorruptedPackage = error {
            unlockErrorKey = "patch.error.wrong_password"
        } else {
            unlockErrorKey = error.localizationKey
        }
    }

    private func present(_ error: PatchPackageError) {
        alert = PatchStoreAlert(
            titleKey: "common.failed",
            messageKey: error.localizationKey,
            messageArgument: error.localizationArgument
        )
    }
}
