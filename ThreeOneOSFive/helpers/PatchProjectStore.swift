import CryptoKit
import Foundation

enum VesperDashDigest {
    static func hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum RemotePackageVault {
    private struct Payload: Codable {
        var packages: [String: Data]
    }

    private static let lock = NSRecursiveLock()
    private static let magic = Data("VSPRVLT1".utf8)

    static func load(for remote: RemotePatch) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let url = try PatchProjectLibrary.remotePackageVaultURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let keyData = try PatchKeyStore.remoteVaultEncryptionKey(createIfMissing: false) else {
            return nil
        }
        let payload = try readPayload(at: url, keyData: keyData)
        guard let data = payload.packages[cacheKey(for: remote)],
              VesperDashDigest.hex(data).caseInsensitiveCompare(remote.sha256) == .orderedSame else {
            return nil
        }
        return data
    }

    static func store(_ data: Data, for remote: RemotePatch) throws {
        guard VesperDashDigest.hex(data).caseInsensitiveCompare(remote.sha256) == .orderedSame else {
            throw PatchPackageError.remoteImportFailed
        }
        lock.lock()
        defer { lock.unlock() }
        let url = try PatchProjectLibrary.remotePackageVaultURL()
        guard let keyData = try PatchKeyStore.remoteVaultEncryptionKey() else {
            throw PatchPackageError.keychainFailed
        }
        var packages: [String: Data]
        if FileManager.default.fileExists(atPath: url.path) {
            packages = (try? readPayload(at: url, keyData: keyData).packages) ?? [:]
        } else {
            packages = [:]
        }
        packages[cacheKey(for: remote)] = data
        try writePayload(Payload(packages: packages), to: url, keyData: keyData)
    }

    static func prune(keeping remotes: [RemotePatch]) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = try PatchProjectLibrary.remotePackageVaultURL()
        guard FileManager.default.fileExists(atPath: url.path),
              let keyData = try PatchKeyStore.remoteVaultEncryptionKey(createIfMissing: false) else {
            return
        }
        let keep = Set(remotes.map { cacheKey(for: $0) })
        let oldPayload = try readPayload(at: url, keyData: keyData)
        let retained = oldPayload.packages.filter { keep.contains($0.key) }
        guard retained.count != oldPayload.packages.count else { return }
        if retained.isEmpty {
            try FileManager.default.removeItem(at: url)
        } else {
            try writePayload(Payload(packages: retained), to: url, keyData: keyData)
        }
    }

    private static func cacheKey(for remote: RemotePatch) -> String {
        VesperDashDigest.hex(Data("\(remote.bundle_id.lowercased())|\(remote.sha256.lowercased())".utf8))
    }

    private static func readPayload(at url: URL, keyData: Data) throws -> Payload {
        let encryptedFile = try Data(contentsOf: url, options: .mappedIfSafe)
        guard encryptedFile.starts(with: magic) else { throw PatchPackageError.invalidProject }
        let combined = encryptedFile.dropFirst(magic.count)
        let sealedBox = try AES.GCM.SealedBox(combined: Data(combined))
        let clearData = try AES.GCM.open(sealedBox, using: SymmetricKey(data: keyData))
        return try PropertyListDecoder().decode(Payload.self, from: clearData)
    }

    private static func writePayload(_ payload: Payload, to url: URL, keyData: Data) throws {
        let clearData = try PropertyListEncoder().encode(payload)
        let sealedBox = try AES.GCM.seal(clearData, using: SymmetricKey(data: keyData))
        guard let combined = sealedBox.combined else { throw PatchPackageError.remoteImportFailed }
        var encryptedFile = magic
        encryptedFile.append(combined)
        try encryptedFile.write(to: url, options: [.atomic, .completeFileProtection])
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
    private static let initialSyncCompletedKey = "vesperdash.initialSyncCompleted.v6"
    private static let authoritativeResetKey = "vesperdash.authoritativeReset.v4"
    private static let remoteEntriesKey = "vesperdash.remoteEntries.v3"
    private static let remoteCategoriesKey = "vesperdash.remoteCategories.v3"
    private static let remoteImagesKey = "vesperdash.remoteImages.v3"
    private static let remoteStatusesKey = "vesperdash.remoteStatuses.v3"
    private static let remoteOrdersKey = "vesperdash.remoteOrders.v3"
    private static let remoteBundlesKey = "vesperdash.remoteBundles.v3"
    private static let remoteProjectIDsKey = "vesperdash.remoteProjectIDs.v1"
    @Published private(set) var items: [PatchLibraryItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var hasManifestSyncError = false
    @Published private(set) var hasCompletedInitialSync = false
    @Published private(set) var isRemoteDisabled = false
    @Published private(set) var remoteSyncMessage = "REMOTE DATA: WAITING"
    @Published private(set) var remoteCategories: [String: String] = [:]
    @Published private(set) var remoteImageURLs: [String: URL] = [:]
    @Published private(set) var remoteStatusTexts: [String: String] = [:]
    @Published private(set) var remoteOrders: [String: Int] = [:]
    @Published private(set) var remoteEntries: [RemotePatch] = []
    @Published private(set) var remoteBundleIDs: [String: String] = [:]
    @Published private(set) var remoteProjectIDs: [String: String] = [:]
    @Published private(set) var preparingRemotePatchKeys: Set<String> = []
    @Published private(set) var preparedRemotePatchKeys: Set<String> = []
    @Published private(set) var failedRemotePatchKeys: Set<String> = []
    @Published private(set) var syncFileNames: [String] = []
    @Published private(set) var syncFinishedFileNames: Set<String> = []
    @Published private(set) var syncFailedFileNames: Set<String> = []
    @Published private(set) var syncDownloadingFileNames: Set<String> = []
    @Published private(set) var syncCurrentFile = ""
    @Published var passwordRequest: PatchPasswordRequest?
    @Published var alert: PatchStoreAlert?
    @Published var unlockErrorKey: String?
    private var digestCache: [String: String] = [:]
    private var lastManifestFingerprint = ""
    private var preparedRemoteProjects: [String: PatchProject] = [:]
    private var remotePreparationGeneration = 0

    private struct PendingUnlock {
        let data: Data
        let summary: PatchPackageSummary
        let existingURL: URL?
    }

    private var pendingUnlock: PendingUnlock?

    init() {
        PatchProjectLibrary.removeBundledPackagesIfNeeded()
        reload()
        hasCompletedInitialSync = UserDefaults.standard.bool(forKey: Self.initialSyncCompletedKey)
        let defaults = UserDefaults.standard
        // Remote catalog data is deliberately not restored from UserDefaults.
        // Showing cached entries before the online sync completes can inject a
        // stale target (for example AIM cache_res in the Hologram screen).
        remoteEntries = []
        remoteCategories = [:]
        remoteImageURLs = [:]
        remoteStatusTexts = [:]
        remoteOrders = [:]
        remoteBundleIDs = [:]
        remoteProjectIDs = defaults.dictionary(forKey: Self.remoteProjectIDsKey) as? [String: String] ?? [:]
    }

    func reload() {
        digestCache = [:]
        items = PatchProjectLibrary.load()
    }

    /// Reconcile bundled resources with Application Support after an app
    /// upgrade, then rebuild the in-memory package list.
    func refreshBundledPackages() {
        // Refresh the local package catalog after remote .3105 downloads.
        reload()
    }

    /// Fetch catalog metadata only. Package payloads are fetched by the user's
    /// explicit INJECT action and are never installed as .3105 files.
    func syncVesperDash(sessionToken: String?, showCompletionAlert: Bool = true) {
        guard !isBusy, let sessionToken, !sessionToken.isEmpty else { return }
        isBusy = true
        hasManifestSyncError = false
        performAuthoritativeResetIfNeeded()
        remoteBundleIDs = [:]
        remoteSyncMessage = "REMOTE DATA: CHECKING CATALOG…"
        syncFileNames = []
        syncFinishedFileNames = []
        syncFailedFileNames = []
        syncDownloadingFileNames = []
        syncCurrentFile = "FETCHING CATALOG"

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await self.fetchManifestWithRetry(sessionToken: sessionToken)
                let catalog = manifest.all_patches ?? manifest.patches
                let fingerprint = await self.manifestFingerprint(for: manifest)
                guard await self.shouldProcessManifest(fingerprint) else {
                    return
                }
                await self.applyRemoteState(paused: manifest.global_paused)
                await self.applyRemoteEntries(catalog)
                await self.pruneDownloadedRemotePackages(catalog)
                await self.finishRemoteSync(
                    showCompletionAlert: showCompletionAlert,
                    patchCount: manifest.patches.count
                )
            } catch {
                await self.failRemoteSync()
            }
        }
    }

    private func fetchManifestWithRetry(sessionToken: String) async throws -> VesperDashManifest {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await VesperDashRemoteSync.fetchManifest(sessionToken: sessionToken)
            } catch {
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(250_000_000 * (attempt + 1)))
                }
            }
        }
        throw lastError ?? PatchPackageError.remoteImportFailed
    }

    func remotePatchKey(for remote: RemotePatch) -> String {
        [remote.id, remote.bundle_id.lowercased(), remote.sha256.lowercased()].joined(separator: "|")
    }

    func hasPreparedRemoteProject(for remote: RemotePatch) -> Bool {
        preparedRemotePatchKeys.contains(remotePatchKey(for: remote))
    }

    func preparedRemoteProject(for remote: RemotePatch) -> PatchProject? {
        preparedRemoteProjects[remotePatchKey(for: remote)]
    }

    func remoteProjectID(for remote: RemotePatch) -> UUID? {
        guard let value = remoteProjectIDs[remotePatchKey(for: remote)] else { return nil }
        return UUID(uuidString: value)
    }

    func isRemotePatchActive(_ remote: RemotePatch) -> Bool {
        guard let projectID = remoteProjectID(for: remote) else { return false }
        return DevicePatchService.latestReceipt(
            projectID: projectID,
            targetBundleID: remote.bundle_id
        ) != nil
    }

    func rememberRemoteProject(_ remote: RemotePatch, projectID: UUID) {
        let relatedEntries = remoteEntries.filter {
            $0.bundle_id == remote.bundle_id &&
            $0.sha256.caseInsensitiveCompare(remote.sha256) == .orderedSame
        }
        for entry in relatedEntries {
            remoteProjectIDs[remotePatchKey(for: entry)] = projectID.uuidString
        }
        remoteProjectIDs[remotePatchKey(for: remote)] = projectID.uuidString
        UserDefaults.standard.set(remoteProjectIDs, forKey: Self.remoteProjectIDsKey)
    }

    func discardRemoteProjectMapping(for remote: RemotePatch) {
        let relatedEntries = remoteEntries.filter {
            $0.bundle_id == remote.bundle_id &&
            $0.sha256.caseInsensitiveCompare(remote.sha256) == .orderedSame
        }
        for entry in relatedEntries {
            remoteProjectIDs.removeValue(forKey: remotePatchKey(for: entry))
        }
        remoteProjectIDs.removeValue(forKey: remotePatchKey(for: remote))
        UserDefaults.standard.set(remoteProjectIDs, forKey: Self.remoteProjectIDsKey)
    }

    func finishRemoteActivation(_ remote: RemotePatch) {
        let relatedEntries = remoteEntries.filter {
            $0.bundle_id == remote.bundle_id &&
            $0.sha256.caseInsensitiveCompare(remote.sha256) == .orderedSame
        }
        for entry in relatedEntries {
            let key = remotePatchKey(for: entry)
            preparedRemoteProjects.removeValue(forKey: key)
            preparedRemotePatchKeys.remove(key)
        }
        let key = remotePatchKey(for: remote)
        preparedRemoteProjects.removeValue(forKey: key)
        preparedRemotePatchKeys.remove(key)
    }

    func discardPreparedRemoteProjects() {
        remotePreparationGeneration += 1
        preparedRemoteProjects.removeAll()
        preparedRemotePatchKeys.removeAll()
    }

    func finishRemoteRestore(_ remote: RemotePatch) {
        let relatedEntries = remoteEntries.filter {
            $0.bundle_id == remote.bundle_id &&
            $0.sha256.caseInsensitiveCompare(remote.sha256) == .orderedSame
        }
        for entry in relatedEntries {
            let key = remotePatchKey(for: entry)
            preparedRemoteProjects.removeValue(forKey: key)
            preparedRemotePatchKeys.remove(key)
            remoteProjectIDs.removeValue(forKey: key)
        }
        let key = remotePatchKey(for: remote)
        preparedRemoteProjects.removeValue(forKey: key)
        preparedRemotePatchKeys.remove(key)
        remoteProjectIDs.removeValue(forKey: key)
        UserDefaults.standard.set(remoteProjectIDs, forKey: Self.remoteProjectIDsKey)
    }

    func prepareRemoteProject(
        for requested: RemotePatch,
        sessionToken: String?
    ) async throws {
        let key = remotePatchKey(for: requested)
        let generation = remotePreparationGeneration
        guard !preparingRemotePatchKeys.contains(key) else { return }
        guard let sessionToken, !sessionToken.isEmpty else {
            failedRemotePatchKeys.insert(key)
            throw PatchPackageError.remoteImportFailed
        }
        preparingRemotePatchKeys.insert(key)
        failedRemotePatchKeys.remove(key)
        defer { preparingRemotePatchKeys.remove(key) }

        do {
            let manifest = try await VesperDashRemoteSync.fetchManifest(sessionToken: sessionToken)
            guard !manifest.global_paused,
                  let remote = manifest.patches.first(where: {
                      $0.id == requested.id &&
                      $0.bundle_id == requested.bundle_id &&
                      $0.sha256.caseInsensitiveCompare(requested.sha256) == .orderedSame &&
                      $0.enabled && !$0.paused
                  }) else {
                throw PatchPackageError.remoteImportFailed
            }

            let cachedPackageData = try? await Task.detached(priority: .utility) {
                try RemotePackageVault.load(for: remote)
            }.value
            let packageData: Data
            if let cachedPackageData {
                packageData = cachedPackageData
            } else {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("vesper-inject-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 300
                configuration.allowsExpensiveNetworkAccess = true
                configuration.allowsConstrainedNetworkAccess = true
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                var packageURL: URL?
                var lastDownloadError: Error?
                for attempt in 0..<3 {
                    do {
                        packageURL = try await VesperDashRemoteSync.downloadPackageFile(
                            for: remote,
                            sessionToken: sessionToken,
                            using: session,
                            into: directory
                        )
                        break
                    } catch {
                        lastDownloadError = error
                        if attempt < 2 {
                            try? await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
                        }
                    }
                }
                guard let packageURL else {
                    throw lastDownloadError ?? PatchPackageError.remoteImportFailed
                }
                packageData = try Data(contentsOf: packageURL, options: .mappedIfSafe)
            }
            let passwords = (manifest.package_passwords ?? []).filter { !$0.isEmpty }
            let project = try await Task.detached(priority: .userInitiated) {
                guard packageData.starts(with: Data("3105PATCH\0".utf8)),
                      VesperDashDigest.hex(packageData).caseInsensitiveCompare(remote.sha256) == .orderedSame else {
                    throw PatchPackageError.remoteImportFailed
                }
                _ = try PatchPackageCodec.inspect(packageData)
                var decoded = try? PatchPackageCodec.decode(packageData, password: nil)
                if decoded == nil {
                    for password in passwords {
                        if let candidate = try? PatchPackageCodec.decode(packageData, password: password) {
                            decoded = candidate
                            break
                        }
                    }
                }
                guard let decoded,
                      decoded.project.allBundleIdentifiers.contains(remote.bundle_id) else {
                    throw PatchPackageError.invalidPasswordOrCorruptedPackage
                }
                return decoded.project
            }.value

            guard generation == remotePreparationGeneration, !Task.isCancelled else {
                throw CancellationError()
            }

            if cachedPackageData == nil {
                do {
                    try await Task.detached(priority: .utility) {
                        try RemotePackageVault.store(packageData, for: remote)
                    }.value
                } catch {
                    log("patch: remote package cache write failed: \(error.localizedDescription)")
                }
            }

            preparedRemoteProjects[key] = project
            preparedRemotePatchKeys.insert(key)
        } catch {
            if generation == remotePreparationGeneration {
                failedRemotePatchKeys.insert(key)
            }
            throw error
        }
    }

    private func pruneDownloadedRemotePackages(_ remotes: [RemotePatch]) {
        Task.detached(priority: .utility) {
            do {
                try RemotePackageVault.prune(keeping: remotes)
            } catch {
                log("patch: remote package vault cleanup failed: \(error.localizedDescription)")
            }
        }
        var itemsToRemove: [PatchLibraryItem] = []
        var mappingsChanged = false
        var staleMappingKeys: [String] = []
        for (key, value) in remoteProjectIDs {
            guard let remote = remotes.first(where: { remotePatchKey(for: $0) == key }) else { continue }
            guard let projectID = UUID(uuidString: value) else {
                staleMappingKeys.append(key)
                continue
            }
            let hasReceipt = DevicePatchService.latestReceipt(
                projectID: projectID,
                targetBundleID: remote.bundle_id
            ) != nil
            if !hasReceipt && !preparedRemotePatchKeys.contains(key) {
                staleMappingKeys.append(key)
            }
        }
        for key in staleMappingKeys {
            remoteProjectIDs.removeValue(forKey: key)
            mappingsChanged = true
        }
        for item in items {
            let packageDigest = digest(for: item)
            guard !packageDigest.isEmpty else { continue }
            let matchingRemotes = remotes.filter {
                $0.sha256.caseInsensitiveCompare(packageDigest) == .orderedSame &&
                (item.project?.allBundleIdentifiers.contains($0.bundle_id) ?? true)
            }
            guard !matchingRemotes.isEmpty else { continue }
            for remote in matchingRemotes where DevicePatchService.latestReceipt(
                projectID: item.id,
                targetBundleID: remote.bundle_id
            ) != nil {
                remoteProjectIDs[remotePatchKey(for: remote)] = item.id.uuidString
            }
            itemsToRemove.append(item)
        }
        for item in itemsToRemove {
            do {
                try PatchProjectLibrary.removePackageFileOnly(item)
            } catch {
                log("patch: could not remove cached remote .3105: \(error)")
            }
        }
        if !itemsToRemove.isEmpty || mappingsChanged {
            UserDefaults.standard.set(remoteProjectIDs, forKey: Self.remoteProjectIDsKey)
        }
        if !itemsToRemove.isEmpty {
            reload()
        }
    }

    private func manifestFingerprint(for manifest: VesperDashManifest) -> String {
        (manifest.all_patches ?? manifest.patches).map {
            [$0.id, $0.name, $0.filename, $0.sha256, $0.bundle_id, $0.target_path,
             $0.normalizedTargetPaths.joined(separator: "\u{1F}"),
             $0.category ?? "", $0.version, $0.download_url, $0.image_url ?? "",
             $0.status_text ?? "", $0.sort_order?.description ?? "", $0.enabled.description,
             $0.paused.description].joined(separator: "|")
        }.joined(separator: "\n")
    }

    private func shouldProcessManifest(_ fingerprint: String) -> Bool {
        if lastManifestFingerprint == fingerprint && hasCompletedInitialSync {
            isBusy = false
            return false
        }
        lastManifestFingerprint = fingerprint
        return true
    }

    private func beginSyncFiles(_ names: [String]) {
        syncFileNames = names
        syncFinishedFileNames = []
        syncFailedFileNames = []
        syncDownloadingFileNames = []
    }

    private func beginSyncFile(_ name: String) {
        syncCurrentFile = name
        syncFailedFileNames.remove(name)
        syncDownloadingFileNames.remove(name)
    }

    private func setSyncDownloadActive(_ name: String, active: Bool) {
        if active {
            syncDownloadingFileNames.insert(name)
        } else {
            syncDownloadingFileNames.remove(name)
        }
    }

    private func recordSyncFailure(_ name: String) {
        syncFailedFileNames.insert(name)
    }

    private func finishSyncFile(_ name: String) {
        syncFinishedFileNames.insert(name)
        syncDownloadingFileNames.remove(name)
    }

    private func setSyncCurrentFile(_ name: String) {
        syncCurrentFile = name
    }

    private func performAuthoritativeResetIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.authoritativeResetKey) else { return }
        // Reset catalog metadata only. Package and workspace files are user data;
        // the first sync after an update must never delete them.
        remoteCategories = [:]
        remoteImageURLs = [:]
        remoteStatusTexts = [:]
        remoteOrders = [:]
        remoteBundleIDs = [:]
        remoteEntries = []
        defaults.removeObject(forKey: Self.remoteEntriesKey)
        defaults.removeObject(forKey: Self.remoteCategoriesKey)
        defaults.removeObject(forKey: Self.remoteImagesKey)
        defaults.removeObject(forKey: Self.remoteStatusesKey)
        defaults.removeObject(forKey: Self.remoteOrdersKey)
        defaults.removeObject(forKey: Self.remoteBundlesKey)
        defaults.set(false, forKey: Self.initialSyncCompletedKey)
        reload()
        defaults.set(true, forKey: Self.authoritativeResetKey)
    }

    private func finishRemoteSync(
        showCompletionAlert: Bool = true,
        patchCount: Int = 0
    ) {
        reload()
        isBusy = false
        hasCompletedInitialSync = true
        hasManifestSyncError = false
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
        var seenEntries = Set<String>()
        remoteEntries = entries.filter { entry in
            // The same .3105 payload may intentionally appear in more than
            // one tab (for example ESP and Hologram). Deduplicate only within
            // the same category and target bundle, not by digest alone.
            let key = [
                entry.normalizedCategory,
                entry.bundle_id.lowercased(),
                entry.sha256.lowercased()
            ].joined(separator: "|")
            return seenEntries.insert(key).inserted
        }
        if let data = try? JSONEncoder().encode(remoteEntries) {
            UserDefaults.standard.set(data, forKey: Self.remoteEntriesKey)
        }
    }

    func remoteEntries(category: String, bundleID: String) -> [RemotePatch] {
        remoteEntries
            .filter {
                $0.normalizedCategory == category &&
                $0.bundle_id == bundleID &&
                (($0.enabled && !$0.paused) || remoteProjectID(for: $0) != nil)
            }
            .sorted {
                if $0.normalizedOrder != $1.normalizedOrder { return $0.normalizedOrder < $1.normalizedOrder }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func localFilename(for remote: RemotePatch) -> String? {
        items.first { item in
            digest(for: item).caseInsensitiveCompare(remote.sha256) == .orderedSame
        }?.packageURL.lastPathComponent
    }

    func localItem(for packageFilename: String, targetBundleID: String) -> PatchLibraryItem? {
        let remote = remoteEntries.first(where: {
            $0.filename.caseInsensitiveCompare(packageFilename) == .orderedSame &&
            $0.bundle_id == targetBundleID
        })

        if let remote {
            if let digestMatch = items.first(where: { item in
                digest(for: item).caseInsensitiveCompare(remote.sha256) == .orderedSame
            }) {
                return digestMatch
            }
        }

        // A filename is only safe when the decoded project explicitly targets
        // this bundle. Normal and Max can legitimately share a filename.
        return items.first { item in
            guard item.packageURL.lastPathComponent.caseInsensitiveCompare(packageFilename) == .orderedSame else {
                return false
            }
            return item.project?.allBundleIdentifiers.contains(targetBundleID) == true
        }
    }

    private func digest(for item: PatchLibraryItem) -> String {
        let key = item.packageURL.standardizedFileURL.path
        if let cached = digestCache[key] { return cached }
        guard let data = try? PatchProjectLibrary.readPackage(at: item.packageURL) else { return "" }
        let value = VesperDashDigest.hex(data)
        digestCache[key] = value
        return value
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
            let digest = self.digest(for: item)
            guard !digest.isEmpty else { continue }
            if let metadata = metadataByDigest[digest], seenDigests.insert(digest).inserted {
                let path = item.packageURL.standardizedFileURL.path
                categories[path] = metadata.category
                if let imageURL = metadata.imageURL {
                    imageURLs[path] = imageURL
                }
                statusTexts[path] = metadata.statusText
                orders[path] = metadata.sortOrder
            } else {
                // Do not delete user-imported local packages during remote sync.
                // Remote packages remain cached in the local package library.
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
        let digest = self.digest(for: item)
        return remoteEntries.first { $0.sha256.caseInsensitiveCompare(digest) == .orderedSame }?.bundle_id
    }

    func remoteTargetPath(for item: PatchLibraryItem, targetBundleID: String) -> String? {
        let digest = self.digest(for: item)
        let remote = remoteEntries.first(where: {
            $0.sha256.caseInsensitiveCompare(digest) == .orderedSame &&
            $0.bundle_id == targetBundleID
        }) ?? remoteEntries.first(where: {
            $0.bundle_id == targetBundleID &&
            $0.name.caseInsensitiveCompare(item.displayName) == .orderedSame
        })
        guard let remote else {
            // A package can be selected before the first catalog metadata pass
            // finishes. Recover only AIM/Magic packages here; BODY/WEAPONS must
            // keep its package target and never receive the cache_res target.
            let name = item.displayName.lowercased()
            guard name.contains("aim") || name.contains("magic") else { return nil }
            return "Documents/contentcache/Compulsory/ios/gameassetbundles/cache_res.GkLlYqzsX4AtTdE55sDMRh9s-JOI~3D"
        }

        // Legacy Hologram entries and new WEAPONS variants use the active Optional shaders asset.
        // Never inherit an old AIM/cache_res target for this category.
        if remote.normalizedCategory == "weapons" {
            return "Documents/contentcache/Optional/ios/gameassetbundles/shaders.P0K3UG2TfecMBhWMMV~2Fu8ReudIk~3D"
        }

        // Keep the old working behavior: AIM receives the exact target_path
        // currently published by the server, including its case-sensitive name.
        return remote.target_path
    }

    private func failRemoteSync() {
        isBusy = false
        hasManifestSyncError = true
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
            self.digest(for: item).caseInsensitiveCompare(digest) == .orderedSame
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
