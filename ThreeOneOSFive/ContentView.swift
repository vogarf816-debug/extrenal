import SwiftUI
import UIKit
import AVFoundation

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @State private var showCleaner = false
    @State private var remoteSyncTask: Task<Void, Never>?
    @State private var fileSafety: [String: Bool] = [:]
    @State private var developerDesign = 0
    @StateObject private var patchStore = PatchProjectStore()
    @State private var patchOperationBusy = false
    @State private var patchMessage = "READY — SELECT A PATCH"
    @State private var patchEnabled: [String: Bool] = [:]
    private let fileNames: [String] = []
    private let normalPatchFiles: [String] = []
    private let maxPatchFiles: [String] = []

    var body: some View {
        TabView {
            appTab(title: "AIM", icon: "scope") { aimTab }
            appTab(title: "ESP", icon: "eye.fill") { espTab }
            appTab(title: "HOLOGRAM", icon: "cube.transparent") { hologramTab }
            appTab(title: "SKIN MOD", icon: "sparkles") { skinModTab }
            appTab(title: "FILE STATUS", icon: "doc.badge.gearshape") { fileStatusTab }
        }
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
        .overlay {
            if patchStore.isRemoteDisabled {
                RemotePauseView()
            }
        }
        .overlay {
            if patchStore.isRemoteSyncing {
                RemoteLoadingView(store: patchStore)
            }
        }
        .sheet(isPresented: $showCleaner) {
            CleanerView()
        }
        .sheet(item: $patchStore.passwordRequest, onDismiss: patchStore.cancelUnlock) { _ in
            PatchUnlockPrompt(store: patchStore)
        }
        .onAppear {
            syncPatchStates()
            patchStore.syncVesperDash(showCompletionAlert: false, showProgress: true)
            startRemoteStateChecks()
        }
        .onDisappear {
            remoteSyncTask?.cancel()
            remoteSyncTask = nil
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, !patchOperationBusy else { return }
            syncPatchStates()
            patchMessage = "READY — SELECT A PATCH"
        }
    }

    private func startRemoteStateChecks() {
        guard remoteSyncTask == nil else { return }
        remoteSyncTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                patchStore.syncVesperDash(showCompletionAlert: false, showProgress: false)
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

    private struct RemoteLoadingView: View {
        @ObservedObject var store: PatchProjectStore
        @State private var spinnerRotation = 0.0

        var body: some View {
            ZStack {
                LinearGradient(
                    colors: [Color.purple.opacity(0.96), Color(red: 0.08, green: 0.01, blue: 0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                VStack(spacing: 18) {
                    VStack(spacing: 7) {
                        Text("DOWNLOAD RESOURCE FROM SERVER")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .multilineTextAlignment(.center)
                        Text(progressText)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(AppTheme.accent)
                    }
                    .foregroundStyle(.white)

                    ProgressView(value: progress)
                        .tint(AppTheme.accent)
                        .scaleEffect(x: 1, y: 1.5, anchor: .center)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.syncFileNames, id: \.self) { name in
                            HStack(spacing: 9) {
                                Image(systemName: store.syncFinishedFileNames.contains(name) ? "checkmark.circle.fill" : (store.syncCurrentFile == name ? "arrow.down.circle.fill" : "circle"))
                                    .foregroundStyle(store.syncFinishedFileNames.contains(name) ? .green : (store.syncCurrentFile == name ? AppTheme.accent : .white.opacity(0.35)))
                                    .rotationEffect(.degrees(store.syncCurrentFile == name && !store.syncFinishedFileNames.contains(name) ? spinnerRotation : 0))
                                Text(name)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(store.syncFinishedFileNames.contains(name) ? 0.55 : 0.95))
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(28)
            }
            .allowsHitTesting(true)
            .onAppear {
                spinnerRotation = 0
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    spinnerRotation = 360
                }
            }
        }

        private var progress: Double {
            guard !store.syncFileNames.isEmpty else { return 0 }
            return Double(store.syncFinishedFileNames.count) / Double(store.syncFileNames.count)
        }

        private var progressText: String {
            let total = store.syncFileNames.count
            let done = store.syncFinishedFileNames.count
            guard total > 0 else { return store.syncCurrentFile }
            return "\(done)/\(total) FILES • \(store.syncCurrentFile)"
        }
    }

    private func appTab<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ZStack {
                AnimatedHyperBackdrop().ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 16) {
                        brandHeader
                        patchStatusBanner
                        content()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tabItem { Label(title, systemImage: icon) }
    }

    private var patchStatusBanner: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("INJECT STATUS")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(AppTheme.accent)
            Text(patchMessage)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.accent.opacity(0.42), lineWidth: 1))
    }

    private var aimTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "AIM", subtitle: "REMOTE AIM PATCHES", icon: "scope")
            patchOptions(
                files: normalPatchFiles,
                category: "aim",
                sectionTitle: "FF NORMAL",
                targetTitle: "FREE FIRE • NORMAL",
                targetBundleID: "com.dts.freefireth"
            )
        }
    }

    private var espTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "ESP", subtitle: "REMOTE ESP PATCHES", icon: "eye.fill")
            patchOptions(files: [], category: "esp", sectionTitle: "FF NORMAL", targetTitle: "FREE FIRE • NORMAL", targetBundleID: "com.dts.freefireth")
        }
    }

    private var hologramTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "HOLOGRAM", subtitle: "REMOTE HOLOGRAM PATCHES", icon: "cube.transparent")
            patchOptions(files: [], category: "hologram", sectionTitle: "FF NORMAL", targetTitle: "FREE FIRE • NORMAL", targetBundleID: "com.dts.freefireth")
        }
    }

    private var skinModTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "SKIN MOD", subtitle: "REMOTE SKIN PATCHES", icon: "sparkles")
            patchOptions(files: [], category: "skin", sectionTitle: "FF NORMAL", targetTitle: "FREE FIRE • NORMAL", targetBundleID: "com.dts.freefireth")
        }
    }

    private var fileStatusTab: some View {
        VStack(spacing: 16) {
            gameIntro(title: "FILE STATUS", subtitle: "REMOTE STATUS CENTER", icon: "doc.badge.gearshape")
            fileStatusPanel
        }
    }

    private var fileStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                panelTitle("PATCH FILES", icon: "checkmark.shield.fill")
                Spacer()
                Text("VESPERDASH")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(AppTheme.secondaryAccent)
            }

            if patchStore.remoteEntries.isEmpty {
                Text("NO FILES ON VESPERDASH")
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

            Text("STATUS IS CONTROLLED ONLY FROM VESPERDASH")
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
            externalChannelCard
            feedbackCard
            devicePanel
        }
    }

    private func gameIntro(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 25, weight: .black))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 54, height: 54)
                .background(AppTheme.paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 22, weight: .black, design: .rounded)).foregroundStyle(AppTheme.paper)
                Text(subtitle).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(AppTheme.secondaryAccent)
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
            VStack(alignment: .leading, spacing: 3) {
                Text("VESPER EXTERNAL")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(AppTheme.paper)
                Text("PATCH CONTROL CENTER")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.7)
                    .foregroundStyle(AppTheme.accent)
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
            panelTitle("DEVICE STATUS", icon: "shield.lefthalf.filled")
            statusRow(icon: "apple.logo", title: "iOS", value: AppInfo.osVersion, color: AppTheme.secondaryAccent)
            statusRow(icon: "iphone", title: "Device", value: AppInfo.displayMachineName, color: AppTheme.secondaryAccent)
            statusRow(icon: "checkmark.seal.fill", title: "Support", value: appState.isSupported ? "SUPPORTED" : "UNSUPPORTED", color: appState.isSupported ? .green : .red)
        }
        .padding(16)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.32), lineWidth: 1))
    }

    private var externalChannelCard: some View {
        Button {
            guard let url = URL(string: "https://t.me/VesperExtrenal") else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(AppTheme.secondaryAccent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.secondaryAccent.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("VESPER EXTERNAL CHANNEL")
                        .font(.system(size: 12, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.paper)
                    Text("t.me/VesperExtrenal")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryAccent)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(AppTheme.secondaryAccent)
            }
            .padding(14)
            .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
                        let package = patchStore.localFilename(for: remote) ?? remote.filename
                        patchCard(
                            name: remote.name,
                            target: targetTitle,
                            package: package,
                            color: index.isMultiple(of: 2) ? AppTheme.accent : AppTheme.secondaryAccent,
                            imageURL: VesperDashRemoteSync.validImageURL(for: remote),
                            state: patchBinding(for: package, targetBundleID: targetBundleID),
                            targetBundleID: targetBundleID
                        )
                    }
                }
            } else {
                Text("NO \(category.uppercased()) PATCHES — ADD FILES FROM VESPERDASH")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.vertical, 10)
            }

        }
    }

    private func patchCard(
        name: String,
        target: String,
        package: String,
        color: Color,
        imageURL: URL? = nil,
        state: Binding<Bool>,
        targetBundleID: String
    ) -> some View {
        PatchOptionCard(name: name, target: target, color: color, imageURL: imageURL, isEnabled: state, isBusy: patchOperationBusy) {
            togglePatch(
                packageFilename: package,
                displayName: name,
                state: state,
                targetBundleID: targetBundleID
            )
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
            Button {
                showCleaner = true
            } label: {
                Label("Clean Cache & Temp", systemImage: "trash.slash.fill")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.accent.opacity(0.52), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open cache and temporary files cleaner")
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
            Text("VESPER • PRONTO")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(AppTheme.accent.opacity(0.8))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(AppTheme.referenceCard, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.secondaryAccent.opacity(0.25), lineWidth: 1))
    }

    private var developerCredits: some View {
        VStack(spacing: 10) {
            Text("VESPER EXTRENAL")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)

            Text("Our Telegram channels")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.secondaryAccent.opacity(0.85))

            HStack(spacing: 10) {
                channelButton(title: "YAGAMI iOS", url: "https://t.me/+5HHaZurHPA9hOWM8")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var developerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image("VesperBanner")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 58, height: 58)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(developerAccent.opacity(0.7), lineWidth: 2))
                VStack(alignment: .leading, spacing: 3) {
                    Text("DEVELOPER INFO")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(developerAccent)
                    Text("YAGAMIxIOS")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(AppTheme.paper)
                }
            }
            Label("DEVELOPER INFO • DESIGN \(developerDesign + 1)", systemImage: developerIcon)
                .font(.system(size: 12, weight: .black, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(AppTheme.accent)
            HStack {
                Text("BUILD")
                Spacer()
                Text("1.2")
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.secondaryAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(developerBackground, in: developerShape)
        .overlay(developerShape.stroke(developerAccent.opacity(0.5), lineWidth: 1))
    }

    private var developerDesignPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEVELOPER STYLES")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(AppTheme.secondaryAccent)
            Picker("Developer style", selection: $developerDesign) {
                ForEach(0..<10, id: \.self) { index in
                    Text("\(index + 1)").tag(index)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Choose developer information design")
        }
        .padding(14)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var extrenalChannelCard: some View {
        Button {
            guard let url = URL(string: "https://t.me/VesperExtrenal") else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(developerAccent)
                    .font(.system(size: 22, weight: .bold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("EXTRENAL CHANNEL")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.paper)
                    Text("@VesperExtrenal")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.paper.opacity(0.62))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(developerAccent)
            }
            .padding(15)
            .background(AppTheme.ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(developerAccent.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Extrenal channel")
    }

    private var feedbackCard: some View {
        Button {
            guard let url = URL(string: "https://t.me/YAGAMIxIOS") else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .foregroundStyle(developerAccent)
                    .font(.system(size: 22, weight: .bold))
                VStack(alignment: .leading, spacing: 3) {
                    Text("FEEDBACK")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.paper)
                    Text("Send feedback to @YAGAMIxIOS")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(AppTheme.paper.opacity(0.62))
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(developerAccent)
            }
            .padding(15)
            .background(AppTheme.ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(developerAccent.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send feedback on Telegram")
    }

    private var developerAccent: Color {
        [AppTheme.accent, AppTheme.secondaryAccent, .cyan, .orange, .pink, .yellow, .mint, .indigo, .teal, .white][developerDesign]
    }

    private var developerIcon: String {
        ["hammer.fill", "sparkles", "bolt.fill", "person.crop.circle.fill", "star.fill", "wand.and.stars", "swift", "paintpalette.fill", "terminal.fill", "crown.fill"][developerDesign]
    }

    private var developerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: CGFloat(12 + (developerDesign % 5) * 4), style: .continuous)
    }

    private var developerBackground: Color {
        developerDesign.isMultiple(of: 2) ? AppTheme.referenceCard : developerAccent.opacity(0.16)
    }

    private var telegramCard: some View {
        Button {
            guard let url = URL(string: "https://t.me/YAGAMIxIOS") else { return }
            UIApplication.shared.open(url)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(AppTheme.paper)
                    .frame(width: 48, height: 48)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("TELEGRAM")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.secondaryAccent)
                    Text("@YAGAMIxIOS")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(AppTheme.paper)
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
        .accessibilityLabel("Open Telegram YAGAMIxIOS")
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
        displayName: String,
        state: Binding<Bool>,
        targetBundleID: String = "com.dts.freefireth"
    ) {
        guard !patchOperationBusy else { return }
        patchStore.refreshBundledPackages()
        guard let item = patchItem(for: packageFilename, targetBundleID: targetBundleID) else {
            let available = patchStore.items.map { $0.packageURL.lastPathComponent }.sorted().joined(separator: ", ")
            patchMessage = "ERROR — PACKAGE NOT FOUND"
            log("patch: package not found: \(packageFilename); available=\(available)")
            return
        }

        let wasEnabled = state.wrappedValue
        patchOperationBusy = true
        patchMessage = "PROCESSING — \(displayName)"
        let project = item.project
        let projectID = item.id

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
                            self.setPatchState(for: packageFilename, targetBundleID: targetBundleID, enabled: false)
                            self.patchMessage = "OFF — NO ACTIVE PATCH FOUND"
                            self.patchOperationBusy = false
                        }
                        return
                    }
                    try DevicePatchService.restore(receipt: receipt)
                    result = .restored
                } else {
                    guard let project else {
                        result = .unavailable("PASSWORD REQUIRED — UNLOCK PACKAGE")
                        DispatchQueue.main.async {
                            self.patchStore.requestUnlock(for: item)
                            self.patchMessage = "PASSWORD REQUIRED — ENTER PACKAGE PASSWORD"
                            self.patchOperationBusy = false
                        }
                        return
                    }
                    let targetedProject: PatchProject
                    let containsCacheResource = project.rules.contains {
                        $0.relativePath.localizedCaseInsensitiveContains("cache_res.")
                    } || project.directories.contains {
                        $0.relativePath.localizedCaseInsensitiveContains("cache_res")
                    }
                    let serverTargetPath = self.patchStore.remoteTargetPath(
                        for: item,
                        targetBundleID: targetBundleID
                    )
                    let targetPath: String?
                    if containsCacheResource {
                        // This is the behavior from the known-good project:
                        // AIM/Magic keeps the cache_res target embedded in the
                        // downloaded package after rebinding its bundle.
                        // The manifest target must not overwrite it.
                        targetPath = nil
                    } else {
                        // Hologram/shaders continue to use the server target.
                        targetPath = serverTargetPath
                    }
                    log("patch: inject package=\(packageFilename) display=\(item.displayName) original=\(project.rules.first?.relativePath ?? "none") target=\(targetPath ?? "package-default")")
                    if let targetPath {
                        targetedProject = project.retargeted(to: targetBundleID, targetPath: targetPath)
                    } else {
                        targetedProject = project.retargeted(to: targetBundleID)
                    }
                    _ = try DevicePatchService.apply(
                        project: targetedProject
                    )
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
                    self.patchMessage = "Inject Successful — \(displayName)"
                    PatchAudioFeedback.bypassActivated()
                case .restored:
                    self.setPatchState(for: packageFilename, targetBundleID: targetBundleID, enabled: false)
                    self.patchMessage = "Restore Successful — \(displayName)"
                    PatchAudioFeedback.originalRestored()
                case .unavailable(let message):
                    self.patchMessage = message
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
    @Binding var isEnabled: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
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
                Image(systemName: "bolt.fill")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(color)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(target)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(color.opacity(0.9))
            }

            Spacer(minLength: 8)

            Text(isEnabled ? "ON" : "OFF")
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(isEnabled ? AppTheme.secondaryAccent : .white.opacity(0.5))
                .frame(width: 28, alignment: .trailing)

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { _ in action() }
            ))
            .labelsHidden()
            .tint(color)
            .scaleEffect(1.05)
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.horizontal, 14)
        .background(
            LinearGradient(colors: [AppTheme.referenceCard.opacity(0.92), Color.black.opacity(0.28)], startPoint: .leading, endPoint: .trailing)
        )
        .shadow(color: isEnabled ? color.opacity(0.28) : .clear, radius: 12, y: 3)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(color.opacity(isEnabled ? 0.55 : 0.18))
                .frame(height: 1)
        }
        .opacity(isBusy ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(target), \(isEnabled ? "On" : "Off")")
    }
}
private enum PatchAudioFeedback {
    private static var player: AVAudioPlayer?

    static func bypassActivated() { play(resource: "ACTIVADA", ext: "wav") }
    static func originalRestored() { play(resource: "DESACTIVADA", ext: "wav") }

    private static func play(resource: String, ext: String) {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else {
            log("audio: missing resource \(resource).\(ext)")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            player = try AVAudioPlayer(contentsOf: url)
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
                colors: [AppTheme.pageBackground, Color(red: 0.16, green: 0.025, blue: 0.24), AppTheme.pageBackground],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(colors: [AppTheme.accent.opacity(0.18), .clear], center: .topTrailing, startRadius: 10, endRadius: 280)
            RadialGradient(colors: [AppTheme.secondaryAccent.opacity(0.12), .clear], center: .bottomLeading, startRadius: 10, endRadius: 320)
            RadialGradient(colors: [Color.blue.opacity(0.055), .clear], center: .center, startRadius: 10, endRadius: 360)
            RadialGradient(colors: [Color.purple.opacity(0.035), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 260)
            GridOverlay()
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
    }
}
