import SwiftUI

struct LicenseActivationView: View {
    @ObservedObject var manager: LicenseManager
    @State private var key = ""
    @State private var introVisible = false
    @State private var logoBreathing = false
    @State private var ringRotating = false
    @FocusState private var keyFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                LoginBackdrop()
                    .ignoresSafeArea()

                Color.black.opacity(0.16)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            Spacer(minLength: 34)

                            brandMark
                                .padding(.bottom, 18)

                            VStack(spacing: 6) {
                                Text("BABA EXTERNAL")
                                    .font(.system(size: 26, weight: .black, design: .rounded))
                                    .tracking(1.1)
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.72)

                                Text("LICENSE ACCESS")
                                    .font(.system(size: 11, weight: .black, design: .rounded))
                                    .tracking(2.2)
                                    .foregroundStyle(AppTheme.secondaryAccent)

                                Text("BABA PANEL • OFFICIAL ACCESS")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .tracking(0.8)
                                    .foregroundStyle(.white.opacity(0.50))
                                    .padding(.top, 2)
                            }
                            .padding(.horizontal, 24)
                            .opacity(introVisible ? 1 : 0)
                            .offset(y: introVisible ? 0 : 12)
                            .padding(.bottom, 24)

                            activationCard
                                .padding(.horizontal, 20)
                                .opacity(introVisible ? 1 : 0)
                                .offset(y: introVisible ? 0 : 20)
                                .id("activation-card")

                            Text("BABA EXTERNAL • SECURE LICENSE CHECK")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .tracking(0.7)
                                .foregroundStyle(.white.opacity(0.38))
                                .padding(.top, 18)
                                .padding(.horizontal, 20)

                            Spacer(minLength: 34)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 28)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: keyFocused) { focused in
                        guard focused else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo("activation-card", anchor: .center)
                        }
                    }
                }
            }
            .onAppear {
                withAnimation(.easeOut(duration: 0.65)) {
                    introVisible = true
                }
                logoBreathing = true
                ringRotating = true
            }
        }
        .preferredColorScheme(.dark)
    }

    private var brandMark: some View {
        ZStack {
            Circle()
                .fill(AppTheme.accent.opacity(0.18))
                .frame(width: 128, height: 128)
                .blur(radius: 24)

            Circle()
                .stroke(AppTheme.accent.opacity(0.28), lineWidth: 1)
                .frame(width: 112, height: 112)

            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(
                    LinearGradient(colors: [AppTheme.accent, AppTheme.secondaryAccent, .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                )
                .frame(width: 120, height: 120)
                .rotationEffect(.degrees(ringRotating ? 360 : 0))
                .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: ringRotating)

            Image("BabaPanelBranding")
                .resizable()
                .scaledToFill()
                .frame(width: 86, height: 86)
                .clipShape(Circle())
                .overlay(Circle().stroke(AppTheme.accent.opacity(0.82), lineWidth: 1.5))
                .shadow(color: AppTheme.accent.opacity(logoBreathing ? 0.34 : 0.12), radius: logoBreathing ? 22 : 10)
        }
        .scaleEffect(logoBreathing ? 1.02 : 0.96)
        .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: logoBreathing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Baba Panel")
    }

    private var activationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: manager.isBusy ? "arrow.triangle.2.circlepath" : "lock.shield.fill")
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(AppTheme.paper)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .rotationEffect(.degrees(manager.isBusy ? 180 : 0))
                    .animation(.easeInOut(duration: 0.35), value: manager.isBusy)

                VStack(alignment: .leading, spacing: 3) {
                    Text(manager.isBusy ? "VERIFYING LICENSE" : "LICENSE REQUIRED")
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                    Text("EXT • BABA PANEL")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.secondaryAccent)
                }
                Spacer(minLength: 0)
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(AppTheme.accent.opacity(0.82))
                    .font(.system(size: 18))
            }

            Text("Enter your Baba External license key to unlock the panel.")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.66))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("LICENSE KEY")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(AppTheme.secondaryAccent)

                HStack(spacing: 10) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(keyFocused ? AppTheme.accent : .white.opacity(0.46))
                    TextField("Enter license key", text: $key)
                        .focused($keyFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { activate() }
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .tint(AppTheme.accent)
                        .accessibilityIdentifier("license-field")
                }
                .padding(.horizontal, 14)
                .frame(height: 54)
                .background(Color.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(keyFocused ? AppTheme.accent.opacity(0.85) : .white.opacity(0.12), lineWidth: keyFocused ? 1.4 : 1)
                )
                .animation(.easeOut(duration: 0.18), value: keyFocused)
            }

            Toggle("Remember key on this device", isOn: $manager.rememberKey)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .tint(AppTheme.accent)

            Button(action: activate) {
                HStack(spacing: 9) {
                    if manager.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    Text(manager.isBusy ? "VERIFYING…" : "VERIFY AND CONTINUE")
                }
                .font(.system(size: 13, weight: .black, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(
                    LinearGradient(colors: [AppTheme.accent, Color(red: 0.54, green: 0.015, blue: 0.05)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.16), lineWidth: 1))
                .shadow(color: AppTheme.accent.opacity(0.32), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || manager.isBusy)
            .opacity(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.52 : 1)
            .animation(.easeOut(duration: 0.18), value: manager.isBusy)

            if let message = manager.message {
                Text(message)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AppTheme.accent.opacity(0.30), lineWidth: 1))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let contactOwner = manager.contactOwner,
               let contactURL = ownerURL(from: contactOwner) {
                Button {
                    UIApplication.shared.open(contactURL)
                } label: {
                    Label("CONTACT LICENSE OWNER", systemImage: "paperplane.fill")
                        .font(.system(size: 10, weight: .black, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(AppTheme.secondaryAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(20)
        .background(.ultraThinMaterial.opacity(0.78), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(Color(red: 0.07, green: 0.008, blue: 0.015).opacity(0.82), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(LinearGradient(colors: [AppTheme.accent.opacity(0.62), .white.opacity(0.10), AppTheme.accent.opacity(0.20)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
        .animation(.easeOut(duration: 0.22), value: manager.message)
        .animation(.easeOut(duration: 0.22), value: manager.contactOwner)
    }

    private func activate() {
        keyFocused = false
        manager.activate(key: key)
    }

    private func ownerURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("@") {
            return URL(string: VesperStringVault.telegramBaseURL + String(trimmed.dropFirst()))
        }
        return URL(string: VesperStringVault.telegramBaseURL + trimmed)
    }
}

struct LoginBackdrop: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.018, green: 0.004, blue: 0.008), Color(red: 0.12, green: 0.008, blue: 0.025), Color(red: 0.018, green: 0.004, blue: 0.008)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(AppTheme.accent.opacity(0.15))
                .frame(width: 260, height: 260)
                .blur(radius: 54)
                .offset(x: drift ? 138 : -128, y: drift ? -265 : -205)

            Circle()
                .fill(AppTheme.secondaryAccent.opacity(0.10))
                .frame(width: 220, height: 220)
                .blur(radius: 52)
                .offset(x: drift ? -130 : 118, y: drift ? 285 : 225)
        }
        .animation(.easeInOut(duration: 8).repeatForever(autoreverses: true), value: drift)
        .onAppear { drift = true }
    }
}
