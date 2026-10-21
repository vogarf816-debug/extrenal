import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appLanguage) private var appLanguage
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var licenseManager: LicenseManager
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var profileKeyText = ""
    @State private var isProfileKeyVisible = false
    @State private var remoteSyncTask: Task<Void, Never>?
    @State private var fileSafety: [String: Bool] = [:]
    @StateObject private var patchStore = PatchProjectStore()
    @State private var patchOperationBusy = false
    @State private var injectingRemotePatchKey: String?
    @State private var restoringPatchKey: String?
    @State private var patchEnabled: [String: Bool] = [:]
    @AppStorage("keepPatchesActiveAfterExit") private var keepPatchesActiveAfterExit = true
    private let fileNames: [String] = []
    private let normalPatchFiles: [String] = []
    private let maxPatchFiles: [String] = []

    var body: some View {
        TabView {
            appTab(title: appLanguage.text("vesper.tab.aim"), icon: "scope") { aimTab }
            appTab(title: appLanguage.text("vesper.tab.hologram"), icon: "cube.transparent") { hologramTab }
            appTab(title: appLanguage.text("vesper.tab.skin_mod"), icon: "sparkles") { skinModTab }
            appTab(title: appLanguage.text("vesper.tab.compatibility"), icon: "iphone") { supportedDeviceTab }
            appTab(title: appLanguage.text("vesper.tab.profile"), icon: "person.crop.circle") { profileTab }
            appTab(title: appLanguage.text("vesper.tab.developer"), icon: "person.crop.circle") { developerTab }
        }
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
        .toolbarBackground(AppTheme.consoleBackground.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarColorScheme(.dark, for: .tabBar)
        .overlay {
            if patchStore.isRemoteDisabled {
                RemotePauseView()
            }
        }
        .sheet(item: $patchStore.passwordRequest, onDismiss: patchStore.cancelUnlock) { _ in
            PatchUnlockPrompt(store: patchStore)
        }
        .onAppear {
            syncPatchStates()
            patchStore.syncVesperDash(sessionToken: licenseManager.clientSessionToken(), showCompletionAlert: false)
            startRemoteStateChecks()
        }
        .onChange(of: patchStore.isBusy) { isBusy in
            if !isBusy { syncPatchStates() }
        }
        .onChange(of: licenseManager.clientSessionRevision) { _ in
            patchStore.syncVesperDash(sessionToken: licenseManager.clientSessionToken(), showCompletionAlert: false)
        }
        .onDisappear {
            remoteSyncTask?.cancel()
            remoteSyncTask = nil
            // Do not restore patches here. When this option is enabled, the
            // package remains active until the user switches it OFF manually.
            if keepPatchesActiveAfterExit {
                log("patch: leaving app without automatic restore")
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                patchStore.discardPreparedRemoteProjects()
                restoreActivePatches()
                return
            }
            guard phase == .active, !patchOperationBusy else { return }
            syncPatchStates()
            patchStore.syncVesperDash(sessionToken: licenseManager.clientSessionToken(), showCompletionAlert: false)
        }
    }

    private func startRemoteStateChecks() {
        guard remoteSyncTask == nil else { return }
        remoteSyncTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                guard scenePhase == .active, !patchOperationBusy else { continue }
                patchStore.syncVesperDash(sessionToken: licenseManager.clientSessionToken(), showCompletionAlert: false)
            }
        }
    }

    private struct RemotePauseView: View {
        var body: some View {
            ZStack {
                Color.black.opacity(0.94).ignoresSafeArea()
                VStack(spacing: 18) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.orange)
                    Text("SERVICE PAUSED")
                        .font(.system(size: 26, weight: .black, design: .rounded))
                    Text("This IPA has been paused by the administrator. Try again later.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 28)
                }
                .foregroundStyle(.white)
            }
            .allowsHitTesting(true)
        }
    }

    private func appTab<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ZStack {
                AnimatedHyperBackdrop().ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        brandHeader
                        content()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(Text(verbatim: title))
            .navigationBarTitleDisplayMode(.inline)
        }
        .tabItem {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: icon)
            }
        }
    }

    private var aimTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "AIM", subtitle: "ONLINE AIM PATCHES", icon: "scope")
            patchOptions(
                files: normalPatchFiles,
                category: "aim",
                sectionTitle: "FF NORMAL",
                targetTitle: "FREE FIRE • NORMAL",
                targetBundleID: "com.dts.freefireth"
            )
        }
    }

    private var hologramTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "HOLOGRAM", subtitle: "ONLINE HOLOGRAM PATCHES", icon: "cube.transparent")
            patchOptions(files: [], category: "hologram", sectionTitle: "FF NORMAL", targetTitle: "FREE FIRE • NORMAL", targetBundleID: "com.dts.freefireth")
        }
    }

    private var skinModTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "SKIN MOD", subtitle: "ONLINE SKIN PATCHES", icon: "sparkles")
            patchOptions(files: [], category: "skin", sectionTitle: "FF NORMAL", targetTitle: "FREE FIRE • NORMAL", targetBundleID: "com.dts.freefireth")
        }
    }

    private var fileStatusTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "FILE STATUS", subtitle: "ONLINE STATUS CENTER", icon: "doc.badge.gearshape")
            fileStatusPanel
        }
    }

    private var fileStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                panelTitle("PATCH FILES", icon: "checkmark.shield.fill")
                Spacer()
                Text("VESPER")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryAccent)
            }

            HStack(spacing: 12) {
                Image(systemName: keepPatchesActiveAfterExit ? "lock.shield.fill" : "lock.open")
                    .foregroundStyle(keepPatchesActiveAfterExit ? AppTheme.secondaryAccent : AppTheme.paper.opacity(0.55))
                VStack(alignment: .leading, spacing: 3) {
                    Text("KEEP PATCH ACTIVE AFTER EXIT")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.paper)
                    Text("OFF only manually — no automatic restore when leaving the app")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.paper.opacity(0.55))
                }
                Spacer()
                Toggle("", isOn: $keepPatchesActiveAfterExit)
                    .labelsHidden()
                    .tint(AppTheme.secondaryAccent)
            }
            .padding(12)
            .background(AppTheme.ink.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if patchStore.remoteEntries.isEmpty {
                Text("NO FILES AVAILABLE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.paper.opacity(0.5))
                    .padding(.vertical, 14)
            } else {
                ForEach(patchStore.remoteEntries.filter { $0.bundle_id == "com.dts.freefireth" }.sorted { first, second in
                    if first.normalizedCategory != second.normalizedCategory { return first.normalizedCategory < second.normalizedCategory }
                    if first.game != second.game { return first.game < second.game }
                    if first.normalizedOrder != second.normalizedOrder { return first.normalizedOrder < second.normalizedOrder }
                    return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
                }) { remote in
                    HStack(spacing: 12) {
                        if let imageURL = VesperDashRemoteSync.validImageURL(for: remote) {
                            AsyncImage(url: imageURL) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else if phase.error != nil { Image(systemName: "doc.fill").foregroundStyle(AppTheme.accent) }
                                else { ProgressView().tint(AppTheme.secondaryAccent) }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        } else {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(AppTheme.secondaryAccent)
                                .frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(remote.name)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.paper)
                            Text("#\(remote.normalizedOrder) • \(remote.normalizedCategory.uppercased()) • \(remote.game.uppercased())")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(AppTheme.secondaryAccent)
                        }
                        Spacer()
                        Text(remote.normalizedStatus)
                            .font(.system(size: 10, weight: .black, design: .rounded))
                            .foregroundStyle(AppTheme.paper)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(AppTheme.ink.opacity(0.7), in: Capsule())
                    }
                    .padding(.vertical, 8)
                    Divider().overlay(AppTheme.paper.opacity(0.1))
                }
            }

            Text("STATUS IS MANAGED BY VESPER")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.paper.opacity(0.52))
                .padding(.top, 5)
        }
        .padding(16)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.25), lineWidth: 1))
    }

    private var developerTab: some View {
        VStack(spacing: 16) {
            developerCard
            telegramCard
            ownerCard
        }
    }

    private var profileTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: appLanguage.text("vesper.profile.title"), subtitle: appLanguage.text("vesper.profile.subtitle"), icon: "person.crop.circle")
            licenseStatusCard
            profileKeyCard
            profileSupportCard
            profileLanguageCard
            profileSignOutButton
        }
        .onAppear(perform: refreshProfileKey)
        .onChange(of: licenseManager.isActive) { _ in refreshProfileKey() }
        .onDisappear { isProfileKeyVisible = false }
    }

    private var licenseStatusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 42, height: 42)
                .background(AppTheme.ink, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(appLanguage.text("vesper.profile.license_time_left"))
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(AppTheme.secondaryAccent)
                if let expiry = licenseManager.expirationDate {
                    TimelineView(.periodic(from: Date(), by: 1)) { timeline in
                        Text(licenseTimeRemaining(until: expiry, now: timeline.date))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.paper)
                    }
                    Text(appLanguage.text("vesper.profile.expires", expiry.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.paper.opacity(0.56))
                } else if licenseManager.hasExpiryInformation && licenseManager.expiryDateWasProvided {
                    Text(appLanguage.text("vesper.profile.expiry_unreadable"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.paper.opacity(0.72))
                } else if licenseManager.hasExpiryInformation {
                    Text(appLanguage.text("vesper.profile.no_expiry"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.paper)
                } else {
                    Text(appLanguage.text(licenseManager.isBusy ? "vesper.profile.checking" : "vesper.profile.expiry_unavailable"))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.paper.opacity(0.72))
                }
                if let lastCheck = licenseManager.lastCheckAttemptAt {
                    Text(appLanguage.text("vesper.profile.last_check", lastCheck.formatted(date: .abbreviated, time: .standard)))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.paper.opacity(0.56))
                } else {
                    Text(appLanguage.text("vesper.profile.silent_check"))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.paper.opacity(0.56))
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.28), lineWidth: 1))
    }

    private func licenseTimeRemaining(until expiry: Date, now: Date) -> String {
        let seconds = Int(expiry.timeIntervalSince(now))
        guard seconds > 0 else { return "EXPIRED" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if days > 0 { return appLanguage.text("vesper.time.days", days, hours, minutes, remainingSeconds) }
        if hours > 0 { return appLanguage.text("vesper.time.hours", hours, minutes, remainingSeconds) }
        if minutes > 0 { return appLanguage.text("vesper.time.minutes", minutes, remainingSeconds) }
        return appLanguage.text("vesper.time.seconds", remainingSeconds)
    }

    private var profileKeyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle(appLanguage.text("vesper.profile.access_key"), icon: "key.fill")
            HStack(spacing: 10) {
                Text(profileKeyText.isEmpty ? appLanguage.text("vesper.profile.key_not_found") : (isProfileKeyVisible ? profileKeyText : String(repeating: "•", count: max(8, min(profileKeyText.count, 24)))))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.paper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Spacer(minLength: 4)
                Button {
                    isProfileKeyVisible.toggle()
                } label: {
                    Image(systemName: isProfileKeyVisible ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isProfileKeyVisible ? "Hide access key" : "Show access key")
            }
            Text(appLanguage.text("vesper.profile.key_saved"))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.paper.opacity(0.58))
        }
        .padding(16)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.25), lineWidth: 1))
    }

    private var profileSupportCard: some View {
        Button {
            guard let url = URL(string: "https://t.me/YAGAMIxIOS") else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLanguage.text("vesper.profile.owner_support"))
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(AppTheme.secondaryAccent)
                    Text(appLanguage.text("vesper.profile.contact_owner"))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.paper)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
            }
            .padding(14)
            .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.accent.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Contact owner support on Telegram")
    }

    private var profileLanguageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelTitle(appLanguage.text("vesper.profile.language"), icon: "globe")
            Picker(appLanguage.text("vesper.profile.choose_language"), selection: $languageCode) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
            .tint(AppTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.25), lineWidth: 1))
    }

    private var profileSignOutButton: some View {
        Button {
            licenseManager.deactivate()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                Text(appLanguage.text("vesper.profile.sign_out"))
            }
            .font(.system(size: 12, weight: .black, design: .rounded))
            .tracking(1)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Removes the saved key from this device and returns to Enter Key")
    }

    private func refreshProfileKey() {
        profileKeyText = licenseManager.rememberedKey() ?? ""
        isProfileKeyVisible = false
    }

    private var supportedDeviceTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "COMPATIBILITY", subtitle: "DEVICE REQUIREMENTS", icon: "iphone")
            devicePanel
            VStack(alignment: .leading, spacing: 12) {
                panelTitle("SUPPORTED IOS VERSIONS", icon: "checkmark.seal.fill")
                Text("iOS 17.0–17.7.x  •  iOS 18.0–18.7.1  •  iOS 26.0–26.6.1")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                Text("iOS 27.0 Developer Beta 1–4 and Public Beta 1–2")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryAccent)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Compatibility is checked using this device and its installed iOS version/build.")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(AppTheme.paper.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.accent.opacity(0.38), lineWidth: 1))
        }
    }

    private func gameIntro(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .black))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 54, height: 54)
                .background(AppTheme.ink, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.paper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(AppTheme.secondaryAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer()
        }
        .padding(16)
        .background(
            LinearGradient(colors: [AppTheme.referenceCard, AppTheme.ink.opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.28), lineWidth: 1))
        .shadow(color: AppTheme.secondaryAccent.opacity(0.12), radius: 18, y: 8)
    }

    private var brandHeader: some View {
        HStack(spacing: 14) {
            Image("VesperEmblem")
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppTheme.accent.opacity(0.65), lineWidth: 1))
            VStack(alignment: .leading, spacing: 3) {
                Text("VESPER")
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(AppTheme.paper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                Text("VESPER • OFFICIAL INFO")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer()
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.16)).frame(width: 54, height: 54).blur(radius: 9)
                Image(systemName: "bolt.horizontal.fill")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.65), lineWidth: 1))
                    .shadow(color: AppTheme.accent.opacity(0.45), radius: 12)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.accent.opacity(0.28), lineWidth: 1))
        .shadow(color: AppTheme.accent.opacity(0.14), radius: 18, y: 7)
    }

    private var devicePanel: some View {
        VStack(spacing: 0) {
            panelTitle("CURRENT DEVICE STATUS", icon: "shield.lefthalf.filled")
            statusRow(icon: "apple.logo", title: "iOS", value: AppInfo.osVersion, color: AppTheme.secondaryAccent)
            statusRow(icon: "iphone", title: "Device", value: AppInfo.displayMachineName, color: AppTheme.secondaryAccent)
            statusRow(icon: "checkmark.seal.fill", title: "Support", value: appState.isSupported ? "SUPPORTED" : "UNSUPPORTED", color: appState.isSupported ? .green : .red)
            Text(appState.isSupported ? "This device and iOS build are within the verified support range." : "This device or iOS build is outside the verified support range.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.paper.opacity(0.62))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
        }
        .padding(16)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.32), lineWidth: 1))
    }

    private func patchOptions(
        files: [String],
        category: String,
        sectionTitle: String,
        targetTitle: String,
        targetBundleID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                panelTitle(sectionTitle, icon: category == "skin" ? "sparkles" : (category == "esp" ? "eye.fill" : (category == "hologram" ? "cube.transparent" : "bolt.fill")))
                Spacer()
                Text("SELECT PATCH")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }

            let remotePatches = patchStore.remoteEntries(category: category, bundleID: targetBundleID)
            if !remotePatches.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(remotePatches.enumerated()), id: \.element.id) { index, remote in
                        let color = index.isMultiple(of: 2) ? AppTheme.accent : AppTheme.secondaryAccent
                        let remoteKey = patchStore.remotePatchKey(for: remote)
                        patchCard(
                            name: remote.name,
                            target: targetTitle,
                            package: remoteKey,
                            color: color,
                            imageURL: VesperDashRemoteSync.validImageURL(for: remote),
                            statusText: remote.displayStatusText,
                            state: patchBinding(for: remoteKey, targetBundleID: targetBundleID),
                            targetBundleID: targetBundleID,
                            remote: remote
                        )
                    }
                }
            } else {
                if patchStore.hasManifestSyncError {
                    Label("SYNCING PATCH CATALOG…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryAccent)
                        .padding(.vertical, 10)
                } else if patchStore.isBusy {
                    Label("SYNCING PATCH CATALOG…", systemImage: "arrow.down.circle")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryAccent)
                        .padding(.vertical, 10)
                } else if patchStore.hasCompletedInitialSync {
                    Text("NO \(category.uppercased()) PATCHES — ADD FILES FROM VESPER")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.vertical, 10)
                } else {
                    Text("WAITING FOR ACTIVATION SESSION…")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.vertical, 10)
                }
            }

        }
    }

    private func injectRemotePatch(_ remote: RemotePatch, targetBundleID: String) {
        guard !patchOperationBusy else { return }
        let remoteKey = patchStore.remotePatchKey(for: remote)
        patchOperationBusy = true
        injectingRemotePatchKey = remoteKey

        Task { @MainActor in
            do {
                try await patchStore.prepareRemoteProject(
                    for: remote,
                    sessionToken: licenseManager.clientSessionToken()
                )
                guard let project = patchStore.preparedRemoteProject(for: remote) else {
                    throw PatchPackageError.remoteImportFailed
                }
                patchStore.rememberRemoteProject(remote, projectID: project.id)
                _ = try await Task.detached(priority: .userInitiated) {
                    try DevicePatchService.apply(project: project)
                }.value

                patchStore.finishRemoteActivation(remote)
                setPatchState(for: remoteKey, targetBundleID: targetBundleID, enabled: true)
                syncPatchStates()
                PatchAudioFeedback.bypassActivated()
            } catch {
                patchStore.discardRemoteProjectMapping(for: remote)
                log("patch: remote inject failed for \(remote.name): \(error)")
            }
            injectingRemotePatchKey = nil
            patchOperationBusy = false
        }
    }

    private func patchCard(
        name: String,
        target: String,
        package: String,
        color: Color,
        imageURL: URL?,
        statusText: String,
        state: Binding<Bool>,
        targetBundleID: String,
        remote: RemotePatch? = nil
    ) -> some View {
        let stateKey = patchStateKey(package, targetBundleID: targetBundleID)
        return PatchOptionCard(
            name: name,
            target: target,
            color: color,
            imageURL: imageURL,
            statusText: statusText,
            isEnabled: state,
            isRestoring: restoringPatchKey == stateKey,
            isBusy: patchOperationBusy
        ) {
            if let remote,
               !patchStore.hasPreparedRemoteProject(for: remote),
               !patchStore.isRemotePatchActive(remote) {
                injectRemotePatch(remote, targetBundleID: targetBundleID)
            } else {
                togglePatch(
                    packageFilename: package,
                    state: state,
                    targetBundleID: targetBundleID,
                    remote: remote
                )
            }
        }
    }

    private func patchBinding(for filename: String, targetBundleID: String) -> Binding<Bool> {
        let key = patchStateKey(filename, targetBundleID: targetBundleID)
        return Binding(
            get: { patchEnabled[key, default: false] },
            set: { patchEnabled[key] = $0 }
        )
    }

    private func patchStateKey(_ filename: String, targetBundleID: String) -> String {
        "\(targetBundleID)::\(filename)"
    }

    private func patchDisplayName(for filename: String) -> String {
        if filename == "OBB.3105" { return "AIMBODY" }
        if filename == "DRAG.3105" { return "AIM DRAG" }
        if filename == "MAGIC.3105" { return "AIM MAGIC" }
        if filename == "DRAGM.3105" { return "AIM DRAG" }
        if filename == "OBBM.3105" { return "AIMBODY" }
        if filename == "MAGICM.3105" { return "MAGIC BULLET" }
        if filename == "WEAPONS.3105" || filename == "WEAPONSM.3105" { return "WEAPONS HOLO" }
        return filename.replacingOccurrences(of: ".3105", with: "")
            .replacingOccurrences(of: " AIM ", with: " • ")
            .replacingOccurrences(of: "M", with: " M")
            .replacingOccurrences(of: "TH", with: " TH")
    }

    private var gameLaunchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            panelTitle("LAUNCH GAME", icon: "arrow.up.forward.app.fill")
            launchButton(title: "FF NORMAL", subtitle: "Free Fire Normal", color: AppTheme.accent, scheme: "freefireth")
        }
    }

    private func launchButton(title: String, subtitle: String, color: Color, scheme: String) -> some View {
        Button { openGame(scheme: scheme) } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .padding(.horizontal, 14)
            .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(color.opacity(0.38), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var footerStatus: some View {
        HStack(spacing: 10) {
            Circle().fill(AppTheme.secondaryAccent).frame(width: 9, height: 9).shadow(color: AppTheme.accent, radius: 6)
            Text("SISTEMA PRONTO")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.72))
            Spacer()
            Text("VESPER • READY")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.accent.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(AppTheme.referenceCard, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.secondaryAccent.opacity(0.25), lineWidth: 1))
    }

    private var developerCard: some View {
        VStack(spacing: 12) {
            Image("VesperEmblem")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 176)
                .background(.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 4) {
                Text("VESPER")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(AppTheme.paper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("Developer information and official social links")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(AppTheme.paper.opacity(0.66))
                Text("developed by yagami")
                    .font(.system(size: 10, weight: .light, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.secondaryAccent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(AppTheme.accent.opacity(0.42), lineWidth: 1))
    }

    private var telegramCard: some View {
        Button {
            guard let url = URL(string: "https://t.me/VesperExternal") else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("OFFICIAL TELEGRAM CHANNEL")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(AppTheme.secondaryAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("VESPER • TELEGRAM")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.paper)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
            }
            .padding(15)
            .background(AppTheme.paper.opacity(0.11), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.accent.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Vesper Telegram channel")
    }

    private var ownerCard: some View {
        Button {
            guard let url = URL(string: "https://t.me/YAGAMIxIOS") else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(AppTheme.ink)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("OWNER CONTACT")
                        .font(.system(size: 9, weight: .black, design: .rounded))
                        .tracking(0.8)
                        .foregroundStyle(AppTheme.secondaryAccent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("OWNER • TELEGRAM")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.paper)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
            }
            .padding(15)
            .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.accent.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Vesper owner Telegram")
    }

    private func channelButton(title: String, url: String) -> some View {
        Button {
            guard let destination = URL(string: url) else { return }
            UIApplication.shared.open(destination)
        } label: {
            Label(title, systemImage: "paperplane.fill")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(AppTheme.accent.opacity(0.18), in: Capsule())
                .overlay(Capsule().stroke(AppTheme.accent.opacity(0.42), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func panelTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .black, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(AppTheme.accent)
    }

    private func statusRow(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 17, weight: .bold)).foregroundStyle(color).frame(width: 24)
            Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.58))
            Spacer()
            Text(value).font(.system(size: 14, weight: .black, design: .rounded)).foregroundStyle(.white)
        }
        .padding(.top, 14)
    }

    private func restoreActivePatches() {
        guard !keepPatchesActiveAfterExit else { return }
        var restoredReceipts = Set<UUID>()
        for item in patchStore.items {
            guard let bundleID = patchStore.remoteBundleID(for: item),
                  let receipt = DevicePatchService.latestReceipt(projectID: item.id, targetBundleID: bundleID),
                  restoredReceipts.insert(receipt.id).inserted else { continue }
            let filename = item.packageURL.lastPathComponent
            Task.detached(priority: .utility) {
                try? DevicePatchService.restore(receipt: receipt)
            }
            setPatchState(for: filename, targetBundleID: bundleID, enabled: false)
        }
        for remote in patchStore.remoteEntries {
            guard let projectID = patchStore.remoteProjectID(for: remote),
                  let receipt = DevicePatchService.latestReceipt(
                    projectID: projectID,
                    targetBundleID: remote.bundle_id
                  ),
                  restoredReceipts.insert(receipt.id).inserted else { continue }
            let remoteKey = patchStore.remotePatchKey(for: remote)
            Task.detached(priority: .utility) {
                do {
                    try DevicePatchService.restore(receipt: receipt)
                    await patchStore.finishRemoteRestore(remote)
                    await MainActor.run {
                        self.syncPatchStates()
                    }
                } catch {
                    log("patch: automatic remote restore failed: \(error.localizedDescription)")
                }
            }
            setPatchState(for: remoteKey, targetBundleID: remote.bundle_id, enabled: false)
        }
    }

    private func syncPatchStates() {
        // Keep the skin toggles in sync as well. Previously only the normal
        // patch list was refreshed, so every skin returned to OFF after a
        // relaunch/background transition even when its receipt was active.
        for filename in normalPatchFiles {
            patchEnabled[patchStateKey(filename, targetBundleID: "com.dts.freefireth")] = isPatchActive(filename, targetBundleID: "com.dts.freefireth")
        }
        for filename in maxPatchFiles {
            patchEnabled[patchStateKey(filename, targetBundleID: "com.dts.freefiremax")] = isPatchActive(filename, targetBundleID: "com.dts.freefiremax")
        }
        for item in patchStore.items {
            guard let bundleID = patchStore.remoteBundleID(for: item) else { continue }
            guard DevicePatchService.latestReceipt(projectID: item.id, targetBundleID: bundleID) != nil else {
                continue
            }
            let filename = item.packageURL.lastPathComponent
            patchEnabled[patchStateKey(filename, targetBundleID: bundleID)] = true
        }
        for remote in patchStore.remoteEntries {
            let key = patchStore.remotePatchKey(for: remote)
            patchEnabled[patchStateKey(key, targetBundleID: remote.bundle_id)] = patchStore.isRemotePatchActive(remote)
        }
    }

    private func isPatchActive(_ packageFilename: String, targetBundleID: String) -> Bool {
        patchItem(for: packageFilename, targetBundleID: targetBundleID)
            .flatMap { DevicePatchService.latestReceipt(projectID: $0.id, targetBundleID: targetBundleID) } != nil
    }

    private func patchItem(for packageFilename: String, targetBundleID: String = "com.dts.freefireth") -> PatchLibraryItem? {
        if let resolved = patchStore.localItem(for: packageFilename, targetBundleID: targetBundleID) {
            return resolved
        }
        let requestedName = (packageFilename as NSString).deletingPathExtension
        let wantsMax = targetBundleID == "com.dts.freefiremax"
        let requestedKey = requestedName.uppercased().hasSuffix("M")
            ? String(requestedName.dropLast()).uppercased()
            : requestedName.uppercased()
        return patchStore.items.first { item in
            let localFilename = item.packageURL.lastPathComponent
            if let data = try? PatchProjectLibrary.readPackage(at: item.packageURL) {
                let digest = VesperDashDigest.hex(data)
                if patchStore.remoteEntries.contains(where: {
                    $0.bundle_id == targetBundleID &&
                    digest.caseInsensitiveCompare($0.sha256) == .orderedSame
                }) {
                    return true
                }
            }
            if localFilename.caseInsensitiveCompare(packageFilename) == .orderedSame {
                if let remoteBundleID = patchStore.remoteBundleID(for: item) {
                    return remoteBundleID == targetBundleID
                }
                return item.project?.allBundleIdentifiers.contains(targetBundleID) == true
            }
            guard matchesTargetBundle(item, targetBundleID: targetBundleID) else { return false }
            let storedName = item.packageURL.deletingPathExtension().lastPathComponent
            let canonicalName = storedName
                .replacingOccurrences(of: "BundledPatch-", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "xTop1 External File (", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: ")"))
            let normalizedStoredName = (canonicalName as NSString).deletingPathExtension
            let storedKey = normalizedStoredName.uppercased()
            let aliasedStoredKey: String
            let gameSuffix = wantsMax ? "M" : ""
            if storedKey.hasPrefix("BODY") {
                aliasedStoredKey = "OBB" + gameSuffix
            } else if storedKey.hasPrefix("DRAG") {
                aliasedStoredKey = "DRAG" + gameSuffix
            } else if storedKey.hasPrefix("MAGIC") {
                aliasedStoredKey = "MAGIC" + gameSuffix
            } else if storedKey.hasPrefix("WEAPON") {
                aliasedStoredKey = "WEAPONS" + gameSuffix
            } else {
                aliasedStoredKey = storedKey
            }
            // The package filename is the authoritative UI-to-resource link.
            // This is required for descriptive project names such as
            // "3D WEAPONS" whose bundled resource is named WEAPONS.3105.
            if normalizedStoredName.caseInsensitiveCompare(requestedName) == .orderedSame {
                return true
            }
            if aliasedStoredKey == requestedName.uppercased() {
                return true
            }
            let projectTargets = item.project?.allBundleIdentifiers ?? []
            let hasRequestedBundle = projectTargets.contains(targetBundleID)
            let isCacheResource = item.project?.directories.contains {
                $0.relativePath.localizedCaseInsensitiveContains("cache_res")
            } == true || item.project?.rules.contains {
                $0.relativePath.localizedCaseInsensitiveContains("cache_res")
            } == true
            if requestedKey == "OBB", hasRequestedBundle, isCacheResource {
                return true
            }
            let projectName = item.project?.name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
            let storedIsMax = normalizedStoredName.uppercased().hasSuffix("M")
            let projectKey = projectName.hasSuffix("M") ? String(projectName.dropLast()) : projectName
            return projectKey == requestedKey && storedIsMax == wantsMax
        }
    }

    private func matchesTargetBundle(_ item: PatchLibraryItem, targetBundleID: String) -> Bool {
        if let remoteBundleID = patchStore.remoteBundleID(for: item) {
            return remoteBundleID == targetBundleID
        }
        return item.project?.allBundleIdentifiers.contains(targetBundleID) == true
    }

    private enum PatchActionResult {
        case applied
        case restored
        case unavailable(String)
    }

    private func setPatchState(for packageFilename: String, targetBundleID: String, enabled: Bool) {
        patchEnabled[patchStateKey(packageFilename, targetBundleID: targetBundleID)] = enabled
    }

    private func togglePatch(
        packageFilename: String,
        state: Binding<Bool>,
        targetBundleID: String = "com.dts.freefireth",
        remote: RemotePatch? = nil
    ) {
        guard !patchOperationBusy else { return }
        patchStore.refreshBundledPackages()
        let item = remote == nil ? patchItem(for: packageFilename, targetBundleID: targetBundleID) : nil
        let remoteProject = remote.flatMap { patchStore.preparedRemoteProject(for: $0) }
        let projectID = item?.id ?? remoteProject?.id ?? remote.flatMap { patchStore.remoteProjectID(for: $0) }
        let wasEnabled = state.wrappedValue

        guard let projectID else {
            return
        }
        if !wasEnabled, item == nil, remoteProject == nil {
            return
        }

        patchOperationBusy = true
        if wasEnabled {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.76)) {
                restoringPatchKey = patchStateKey(packageFilename, targetBundleID: targetBundleID)
            }
        }
        let project = item?.project ?? remoteProject
        if !wasEnabled, let remote {
            patchStore.rememberRemoteProject(remote, projectID: projectID)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result: PatchActionResult
            do {
                if wasEnabled {
                    guard let receipt = DevicePatchService.latestReceipt(
                        projectID: projectID,
                        targetBundleID: targetBundleID
                    ) else {
                        result = .unavailable("NO ACTIVE RECEIPT — NOTHING TO RESTORE")
                        DispatchQueue.main.async {
                            if let remote { self.patchStore.finishRemoteRestore(remote) }
                            self.syncPatchStates()
                            withAnimation(.easeOut(duration: 0.24)) {
                                self.setPatchState(for: packageFilename, targetBundleID: targetBundleID, enabled: false)
                                self.restoringPatchKey = nil
                            }
                            self.patchOperationBusy = false
                        }
                        return
                    }
                    try DevicePatchService.restore(receipt: receipt)
                    result = .restored
                } else {
                    guard let project else {
                        if let item, item.project == nil {
                            DispatchQueue.main.async {
                                self.patchStore.requestUnlock(for: item)
                                self.patchOperationBusy = false
                            }
                            return
                        }
                        result = .unavailable("PATCH DATA IS NO LONGER PREPARED — TAP INJECT")
                        DispatchQueue.main.async {
                            if let remote { self.patchStore.discardRemoteProjectMapping(for: remote) }
                            self.patchOperationBusy = false
                        }
                        return
                    }
                    log("patch: applying decoded project without persisting .3105 package=\(packageFilename) target=\(project.rules.first?.relativePath ?? "none")")
                    _ = try DevicePatchService.apply(project: project)
                    result = .applied
                }
            } catch let error as PatchPackageError {
                if case .missingTarget(let path) = error {
                    result = .unavailable("MISSING TARGET — \(path)")
                } else {
                    result = .unavailable("FAILED — \(error.localizedDescription)")
                }
            } catch {
                result = .unavailable("FAILED — \(error.localizedDescription)")
            }

            DispatchQueue.main.async {
                switch result {
                case .applied:
                    self.setPatchState(for: packageFilename, targetBundleID: targetBundleID, enabled: true)
                    if let remote {
                        self.patchStore.finishRemoteActivation(remote)
                        self.syncPatchStates()
                    }
                    PatchAudioFeedback.bypassActivated()
                case .restored:
                    if let remote {
                        self.patchStore.finishRemoteRestore(remote)
                        self.syncPatchStates()
                    }
                    withAnimation(.spring(response: 0.48, dampingFraction: 0.74)) {
                        self.setPatchState(for: packageFilename, targetBundleID: targetBundleID, enabled: false)
                        self.restoringPatchKey = nil
                    }
                    PatchAudioFeedback.originalRestored()
                case .unavailable(let message):
                    if let remote, !wasEnabled { self.patchStore.discardRemoteProjectMapping(for: remote) }
                    log("patch: action unavailable: \(message)")
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.restoringPatchKey = nil
                    }
                }
                self.patchOperationBusy = false
            }
        }
    }

    private func openGame(scheme: String) {
        guard let url = URL(string: "\(scheme)://") else { return }
        UIApplication.shared.open(url, options: [:]) { success in
            log("launch: \(scheme) success=\(success)")
        }
    }
}

private struct PatchOptionCard: View {
    let name: String
    let target: String
    let color: Color
    let imageURL: URL?
    let statusText: String
    @Binding var isEnabled: Bool
    let isRestoring: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        Image(systemName: "photo").foregroundStyle(color)
                    } else {
                        ProgressView().tint(color)
                    }
                }
                .frame(width: 48, height: 48)
                .background(Color.black.opacity(0.28))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Color.clear.frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: 20, alignment: .leading)
                Text(isEnabled ? "INJECTED" : target)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(color.opacity(0.9))
                    .frame(height: 12, alignment: .leading)
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryAccent.opacity(0.82))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
            Button(action: action) {
                Text(isRestoring ? "RESTORING…" : (isEnabled ? "INJECTED" : "INJECT"))
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .lineLimit(1)
                    .frame(width: 92, height: 32, alignment: .center)
                .foregroundStyle(AppTheme.secondaryAccent)
                .background(
                    AppTheme.secondaryAccent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(AppTheme.secondaryAccent.opacity(0.72), lineWidth: 1.1)
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
        }
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.horizontal, 14)
        .background(
            LinearGradient(
                colors: [AppTheme.referenceCard.opacity(0.92), Color.black.opacity(0.28)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .shadow(color: .clear, radius: 0, y: 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText.isEmpty ? "\(name), \(target), \(isEnabled ? "Injected" : "Not injected")" : "\(name), \(target), \(statusText), \(isEnabled ? "Injected" : "Not injected")")
    }
}

enum EmbeddedAppResources {
    private static let payloadMagic = Array("VSPRPAY1".utf8)
    private static let footerMagic = Array("VSPRFTR1".utf8)
    private static let footerSize = 24
    private static let resources = loadResources()

    static func data(named name: String) -> Data? {
        resources[name]
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    private static func loadResources() -> [String: Data] {
        guard let executableURL = Bundle.main.executableURL,
              let handle = try? FileHandle(forReadingFrom: executableURL) else { return [:] }
        defer { try? handle.close() }

        do {
            let fileSize = try handle.seekToEnd()
            guard let (payloadOffset, payloadSize) = try findPayload(handle: handle, fileSize: fileSize),
                  payloadSize <= 16_000_000 else { return [:] }
            try handle.seek(toOffset: payloadOffset)
            guard let payloadData = try handle.read(upToCount: Int(payloadSize)),
                  payloadData.count == Int(payloadSize) else { return [:] }
            let bytes = [UInt8](payloadData)
            guard Array(bytes.prefix(payloadMagic.count)) == payloadMagic,
                  bytes.count >= payloadMagic.count + 4 else { return [:] }

            var cursor = payloadMagic.count
            guard let recordCount = readUInt32(bytes, at: cursor) else { return [:] }
            cursor += 4
            guard recordCount == 7 else { return [:] }
            var result: [String: Data] = [:]

            for _ in 0..<recordCount {
                guard let nameSize = readUInt16(bytes, at: cursor),
                      let contentSize = readUInt64(bytes, at: cursor + 2) else { return [:] }
                cursor += 10
                guard nameSize > 0, contentSize <= UInt64(bytes.count),
                      cursor + Int(nameSize) <= bytes.count else { return [:] }
                let nameEnd = cursor + Int(nameSize)
                guard let name = String(bytes: bytes[cursor..<nameEnd], encoding: .utf8) else { return [:] }
                let contentStart = nameEnd
                let contentEnd = contentStart + Int(contentSize)
                guard contentEnd <= bytes.count else { return [:] }
                result[name] = Data(bytes[contentStart..<contentEnd])
                cursor = contentEnd
            }
            guard cursor == bytes.count,
                  Set(result.keys) == Set(["ACTIVADA.m4a", "DESACTIVADA.m4a", "Assets.car", "PkgInfo", "Info.plist", "AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"]) else { return [:] }
            return result
        } catch {
            log("audio: could not read embedded resources: \(error)")
            return [:]
        }
    }

    private static func findPayload(handle: FileHandle, fileSize: UInt64) throws -> (UInt64, UInt64)? {
        let blockSize: UInt64 = 1_048_576
        var scanEnd = fileSize
        while scanEnd > 0 {
            let scanStart = scanEnd > blockSize ? scanEnd - blockSize : 0
            try handle.seek(toOffset: scanStart)
            let blockData = try handle.read(upToCount: Int(scanEnd - scanStart)) ?? Data()
            let block = [UInt8](blockData)
            if block.count >= footerSize {
                for position in stride(from: block.count - footerSize, through: 0, by: -1) {
                    guard Array(block[position..<(position + footerMagic.count)]) == footerMagic,
                          let payloadOffset = readUInt64(block, at: position + footerMagic.count),
                          let payloadSize = readUInt64(block, at: position + footerMagic.count + 8),
                          payloadSize > 0,
                          payloadOffset + payloadSize == scanStart + UInt64(position) else { continue }
                    return (payloadOffset, payloadSize)
                }
            }
            if scanStart == 0 { break }
            scanEnd = scanStart + UInt64(footerSize - 1)
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
    }
}

private enum PatchAudioFeedback {
    private static var player: AVAudioPlayer?

    static func bypassActivated() { play(resource: "ACTIVADA", ext: "m4a") }
    static func originalRestored() { play(resource: "DESACTIVADA", ext: "m4a") }

    private static func play(resource: String, ext: String) {
        let resourceName = "\(resource).\(ext)"
        guard let audioData = EmbeddedAppResources.data(named: resourceName) else {
            log("audio: missing embedded resource \(resourceName)")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            player = try AVAudioPlayer(data: audioData)
            player?.prepareToPlay()
            player?.play()
        } catch {
            log("audio: failed to play \(resource): \(error)")
        }
    }
}
private struct PatchUnlockPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: PatchProjectStore
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Package password", text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(unlock)
                        .onChange(of: password) { _ in store.clearUnlockError() }
                    if let errorKey = store.unlockErrorKey {
                        Text(AppLanguage.english.text(errorKey))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Enter the password once to unlock this 3105 package on this device.")
                }
            }
            .navigationTitle("Unlock package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock", action: unlock)
                        .disabled(password.isEmpty || store.isBusy)
                }
            }
        }
    }

    private func unlock() {
        guard !password.isEmpty else { return }
        store.unlock(password: password)
    }
}

struct AnimatedHyperBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [AppTheme.pageBackground, Color.black, AppTheme.consoleBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(colors: [AppTheme.accent.opacity(0.12), .clear], center: .topTrailing, startRadius: 8, endRadius: 260)
        }
    }
}

private struct EmberField: View {
    private let embers: [(x: CGFloat, y: CGFloat, size: CGFloat, phase: Double)] = [
        (0.08, 0.15, 4, 0.2), (0.22, 0.32, 3, 1.1), (0.38, 0.12, 5, 2.4),
        (0.56, 0.28, 3, 0.8), (0.74, 0.10, 4, 1.8), (0.91, 0.25, 3, 2.8),
        (0.16, 0.62, 3, 1.6), (0.34, 0.82, 4, 2.2), (0.63, 0.70, 3, 0.5),
        (0.82, 0.88, 5, 1.3), (0.95, 0.56, 3, 2.6)
    ]

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                for ember in embers {
                    let drift = CGFloat(sin(time * 1.4 + ember.phase) * 8)
                    let rise = CGFloat((time * 12 + ember.phase * 18).truncatingRemainder(dividingBy: 34))
                    let point = CGPoint(x: size.width * ember.x + drift, y: size.height * ember.y - rise)
                    let glow = Path(ellipseIn: CGRect(x: point.x - ember.size * 2.2, y: point.y - ember.size * 2.2, width: ember.size * 4.4, height: ember.size * 4.4))
                    context.fill(glow, with: .color(AppTheme.accent.opacity(0.12)))
                    let spark = Path(ellipseIn: CGRect(x: point.x - ember.size / 2, y: point.y - ember.size / 2, width: ember.size, height: ember.size))
                    context.fill(spark, with: .color(AppTheme.accent.opacity(0.82)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct GridOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let spacing: CGFloat = 44
            stride(from: CGFloat(0), through: size.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: CGFloat(0), through: size.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(AppTheme.accent.opacity(0.055)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

private struct PanelScanner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: false)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                let scanY = CGFloat(time.truncatingRemainder(dividingBy: 5.0) / 5.0) * size.height
                var scanLine = Path()
                scanLine.move(to: CGPoint(x: 0, y: scanY))
                scanLine.addLine(to: CGPoint(x: size.width, y: scanY))
                context.stroke(scanLine, with: .color(AppTheme.accent.opacity(0.20)), lineWidth: 1.2)

                let center = CGPoint(x: size.width * 0.84, y: size.height * 0.18)
                for radius in [CGFloat(24), 42, 60] {
                    let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                    context.stroke(circle, with: .color(AppTheme.secondaryAccent.opacity(0.14)), lineWidth: 0.8)
                }

                let angle = time * 0.72
                let rayEnd = CGPoint(x: center.x + CGFloat(cos(angle) * 60), y: center.y + CGFloat(sin(angle) * 60))
                var ray = Path()
                ray.move(to: center)
                ray.addLine(to: rayEnd)
                context.stroke(ray, with: .color(AppTheme.accent.opacity(0.42)), lineWidth: 1.1)
            }
        }
        .allowsHitTesting(false)
    }
}
