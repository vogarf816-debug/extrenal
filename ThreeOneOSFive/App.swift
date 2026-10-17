import SwiftUI
import UIKit

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var licenseManager = LicenseManager()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator();
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage("vesperWelcomeShownOnce") private var hasShownWelcome = false
    @State private var showWelcome = false
    @State private var showSecurityAlert: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        setupLogCapture()
#if !DEBUG
        _showSecurityAlert = State(initialValue: EmbeddedAppResources.identityWasModified())
#else
        _showSecurityAlert = State(initialValue: false)
#endif
        log("app: VESPER launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    var body: some Scene {
        WindowGroup {
            if showSecurityAlert {
                Color.black
                    .ignoresSafeArea()
                    .alert("Security Alert", isPresented: $showSecurityAlert) {
                        Button("OK", role: .destructive) {
                            fatalError("The external name or bundle identifier was modified.")
                        }
                    } message: {
                        Text("The external name or bundle identifier was modified. For security reasons, this product cannot be used after those changes.")
                    }
            } else {
                Group {
                    if licenseManager.isActive {
                        ZStack {
                            ContentView()
                                .environmentObject(licenseManager)
                            if showWelcome {
                                WelcomeView()
                                    .zIndex(1)
                            }
                        }
                    } else {
                        LicenseActivationView(manager: licenseManager)
                    }
                }
                .environmentObject(appState)
                .environmentObject(patchDraftCoordinator)
                .environmentObject(fileOperationCoordinator)
                .environment(\.appLanguage, language)
                .environment(\.locale, language.locale)
            .onChange(of: licenseManager.isActive) { active in
                guard active else { return }
                appState.detectSupport()
                presentWelcomeOnce()
            }
            .onAppear {
                if licenseManager.isActive {
                    appState.detectSupport()
                    presentWelcomeOnce()
                }
                licenseManager.beginLaunchSession()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    guard licenseManager.hasRememberedKey else { return }
                    licenseManager.beginLaunchSession()
                } else {
                    licenseManager.cancelPendingSilentCheck()
                }
            }
            .onOpenURL { url in
                patchDraftCoordinator.presentImport(url)
            }
            .preferredColorScheme(.dark)
            }
        }
    }

    private func presentWelcomeOnce() {
        guard !hasShownWelcome else { return }
        hasShownWelcome = true
        showWelcome = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            showWelcome = false
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}


private struct WelcomeView: View {
    var body: some View {
        ZStack {
            AnimatedHyperBackdrop().ignoresSafeArea()
            VStack(spacing: 16) {
                Image("VesperEmblem")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 112)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AppTheme.accent.opacity(0.7), lineWidth: 1))
                Text("WELCOME TO VESPER EXTERNAL")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.42), lineWidth: 1))
            .padding(24)
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("vesper-welcome-screen")
    }
}
