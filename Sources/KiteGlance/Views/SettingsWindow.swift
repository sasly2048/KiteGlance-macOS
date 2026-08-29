import SwiftUI
import AppKit
import KiteGlanceCore

struct SettingsWindow: View {
    /// `KiteService` is an actor, not an `ObservableObject`, so it cannot be
    /// observed. This view only ever calls methods on it; it never reads
    /// published state, so a plain reference is what it actually needs.
    let kiteService: KiteService
    let onSave: () -> Void
    /// Injected by the window controller so Save can close the NSWindow.
    /// `@Environment(\.dismiss)` does nothing inside an NSHostingView that the
    /// app owns directly -- there is no presentation for SwiftUI to dismiss.
    let onClose: () -> Void

    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var refreshIntervalMinutes: Int = RefreshInterval.default
    @State private var themeMode: ThemeMode = .system

    @Environment(\.colorScheme) private var colorScheme

    /// Resolved from the live picker value rather than read from the
    /// environment: this view *provides* the palette below, so reading the
    /// inherited one here would lag a change by a frame.
    private var palette: Palette {
        Palette.of(ResolvedTheme.resolve(mode: themeMode, systemIsDark: colorScheme == .dark))
    }

    /// Applied as the user changes them, not on Save: these are preferences, not
    /// credentials, and a picker that only takes effect after pressing Save
    /// beside two text fields reads as though it did nothing.
    let onPreferencesChange: (Int, ThemeMode) -> Void
    /// Re-themes the NSWindow itself. The SwiftUI environment does not reach
    /// the titlebar or the blur material behind this view.
    let onChrome: (ThemeMode) -> Void
    let initialRefreshIntervalMinutes: Int
    let initialThemeMode: ThemeMode

    init(
        kiteService: KiteService,
        refreshIntervalMinutes: Int = RefreshInterval.default,
        themeMode: ThemeMode = .system,
        onPreferencesChange: @escaping (Int, ThemeMode) -> Void = { _, _ in },
        onChrome: @escaping (ThemeMode) -> Void = { _ in },
        onSave: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.kiteService = kiteService
        self.initialRefreshIntervalMinutes = refreshIntervalMinutes
        self.initialThemeMode = themeMode
        self.onPreferencesChange = onPreferencesChange
        self.onChrome = onChrome
        self.onSave = onSave
        self.onClose = onClose
    }

    var body: some View {
        content
            // Driven by the live `themeMode` @State, so changing the Appearance
            // picker re-themes this window immediately.
            .environment(\.palette, .of(ResolvedTheme.resolve(
                mode: themeMode,
                systemIsDark: colorScheme == .dark
            )))
            .preferredColorScheme(
                ResolvedTheme.resolve(mode: themeMode, systemIsDark: colorScheme == .dark) == .dark
                    ? .dark : .light
            )
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.tertiary)
                        .frame(width: 28, height: 28)
                        .background(palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .background(palette.surface)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 1)
            }

            // Content
            VStack(alignment: .leading, spacing: 20) {
                Text("Create an app at ")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                + Text("developers.kite.trade")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.primary)
                + Text(", then set its Redirect URL to")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)

                Text("http://127.0.0.1:5173/callback")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("API key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.tertiary)

                    TextField("", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(palette.hairline, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API secret")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.tertiary)

                    SecureField("", text: $apiSecret)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(palette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(palette.hairline, lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Refresh every")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.tertiary)

                    Picker("", selection: $refreshIntervalMinutes) {
                        // Off is a real choice, not a failure to configure.
                        Text("Off").tag(0)
                        ForEach(RefreshInterval.choices, id: \.self) { minutes in
                            Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: 12.5))
                    .accessibilityLabel("Refresh interval")

                    Text("Auto-refresh only runs while the market is open.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.faint)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Appearance")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.tertiary)

                    Picker("", selection: $themeMode) {
                        ForEach(ThemeMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.system(size: 12.5))
                    .accessibilityLabel("Appearance")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.negative)
                        .transition(.opacity)
                }

                Button(action: save) {
                    Text(isSaving ? "Saving…" : "Save")
                        .font(.system(size: 12.5, weight: .semibold))
                        // On the blue gradient in both themes, so not a palette
                        // colour: white is the correct contrast either way.
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            LinearGradient(
                                colors: [Color(red: 0x33/255, green: 0x95/255, blue: 1), Color.blue],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(isSaving
                    || apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("Encrypted with macOS Keychain. Stays on this device.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.faint)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .frame(width: 400, height: 470)
        // Partially transparent so the NSVisualEffectView behind it reads
        // through. An opaque fill here would defeat the blur entirely.
        .background(palette.chrome)
        .task {
            refreshIntervalMinutes = initialRefreshIntervalMinutes
            themeMode = initialThemeMode
            if let creds = await CredentialVault().load() {
                // Only the API key is echoed back; the secret is left blank so
                // opening Settings does not put it on screen. An empty field on
                // Save means "keep the stored secret". This matches the Windows
                // behaviour introduced for the same reason: the secret is the
                // half of the credentials that should never appear on screen
                // unless the user is actively editing it.
                apiKey = creds.apiKey
            }
        }
        .onChange(of: refreshIntervalMinutes) { _, _ in
            onPreferencesChange(refreshIntervalMinutes, themeMode)
        }
        .onChange(of: themeMode) { _, _ in
            onPreferencesChange(refreshIntervalMinutes, themeMode)
            onChrome(themeMode)
        }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let secretInput = apiSecret.trimmingCharacters(in: .whitespaces)

        guard !key.isEmpty else {
            errorMessage = "The API key is required."
            return
        }

        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                // An empty secret field means "keep what is already stored":
                // the Settings window deliberately does not echo the secret
                // back when it opens. Without this branch, the first Save
                // after a successful setup would silently wipe the secret.
                let secret: String
                if secretInput.isEmpty {
                    let existing = try await CredentialVault().load()
                    guard let existing else {
                        errorMessage = "The API secret is required."
                        return
                    }
                    secret = existing.apiSecret
                } else {
                    secret = secretInput
                }

                try await CredentialVault().save(
                    Credentials(apiKey: key, apiSecret: secret, accessToken: nil, savedAt: Date())
                )
                await kiteService.reloadCredentials()
                onSave()
                onClose()
            } catch {
                // Surface the Keychain failure. Silently closing would leave the
                // user believing credentials were stored when they were not.
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A class, not a struct: `NSWindowController` is a class, and a struct cannot
/// inherit from one. The previous declaration could not compile.
final class SettingsWindowController: NSWindowController {
    convenience init(
        kiteService: KiteService,
        refreshIntervalMinutes: Int = RefreshInterval.default,
        themeMode: ThemeMode = .system,
        onPreferencesChange: @escaping (Int, ThemeMode) -> Void = { _, _ in },
        onSave: @escaping () -> Void
    ) {
        // `.titled` with a close button, rather than `.borderless`: a borderless
        // window cannot become key, so the API key and secret fields would never
        // receive keyboard focus -- the settings pane would be unusable.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()

        self.init(window: window)

        let view = SettingsWindow(
            kiteService: kiteService,
            refreshIntervalMinutes: refreshIntervalMinutes,
            themeMode: themeMode,
            onPreferencesChange: onPreferencesChange,
            onChrome: { [weak window] mode in
                window?.appearance = NSAppearance(
                    named: Palette.of(ResolvedTheme.resolve(
                        mode: mode,
                        systemIsDark: NSApp.effectiveAppearance.isDark
                    )).appearance
                )
            },
            onSave: onSave,
            onClose: { [weak window] in window?.close() }
        )
        // The macOS equivalent of the Windows build's acrylic Settings window
        // (WindowMaterial.Apply(acrylic: true)). NSVisualEffectView samples what
        // is behind the window; the ~90 lines of DWM attribute calls that
        // Windows needs have no counterpart here.
        // The titlebar, the blur material and the window's own appearance are
        // drawn by AppKit, which the SwiftUI environment cannot reach. Setting
        // the appearance is what actually themes the chrome.
        window.appearance = NSAppearance(
            named: Palette.of(ResolvedTheme.resolve(
                mode: themeMode,
                systemIsDark: NSApp.effectiveAppearance.isDark
            )).appearance
        )

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.frame = window.contentView?.bounds ?? .zero
        effect.autoresizingMask = [.width, .height]

        // `view` themes itself from its own @State via ThemedContainer in its
        // body, so the picker re-themes live. Wrapping it here in a container
        // built from the *initial* mode would freeze it at launch instead.
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = effect.bounds
        hostingView.autoresizingMask = [.width, .height]

        effect.addSubview(hostingView)
        window.contentView = effect
    }
}