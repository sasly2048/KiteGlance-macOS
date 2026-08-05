import SwiftUI
import AppKit

struct SettingsWindow: View {
    @ObservedObject var kiteService: KiteService
    let onSave: () -> Void

    @State private var apiKey = ""
    @State private var apiSecret = ""
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(kiteService: KiteService, onSave: @escaping () -> Void) {
        self.kiteService = kiteService
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 1, opacity: 0.3))
                        .frame(width: 28, height: 28)
                        .background(Color(white: 1, opacity: 0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 20)
            .background(Color(white: 1, opacity: 0.05))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(white: 1, opacity: 0.08))
                    .frame(height: 1)
            }

            // Content
            VStack(alignment: .leading, spacing: 20) {
                Text("Create an app at ")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 1, opacity: 0.55))
                + Text("developers.kite.trade")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                + Text(", then set its Redirect URL to")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 1, opacity: 0.55))

                Text("http://127.0.0.1:5173/callback")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.blue)

                VStack(alignment: .leading, spacing: 6) {
                    Text("API key")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 1, opacity: 0.3))

                    TextField("", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(Color(white: 1, opacity: 0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(white: 1, opacity: 0.08), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API secret")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(white: 1, opacity: 0.3))

                    SecureField("", text: $apiSecret)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(Color(white: 1, opacity: 0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(white: 1, opacity: 0.08), lineWidth: 1)
                        )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.red)
                        .transition(.opacity)
                }

                Button(action: save) {
                    Text("Save")
                        .font(.system(size: 12.5, weight: .semibold))
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
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || apiSecret.trimmingCharacters(in: .whitespaces).isEmpty)

                Text("Encrypted with macOS Keychain. Stays on this device.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(white: 1, opacity: 0.18))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 26)
            .padding(.top, 20)
            .padding(.bottom, 22)
        }
        .frame(width: 400, height: 342)
        .background(Color(white: 0.07, opacity: 0.95))
        .onAppear {
            Task {
                if let creds = await CredentialVault().load() {
                    apiKey = creds.apiKey
                    apiSecret = creds.apiSecret
                }
            }
        }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let secret = apiSecret.trimmingCharacters(in: .whitespaces)

        guard !key.isEmpty, !secret.isEmpty else {
            errorMessage = "Both the API key and secret are required."
            return
        }

        Task {
            do {
                try await CredentialVault().save(Credentials(apiKey: key, apiSecret: secret, accessToken: nil, savedAt: Date()))
                await kiteService.reloadCredentials()
                onSave()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct SettingsWindowController: NSWindowController {
    convenience init(kiteService: KiteService, onSave: @escaping () -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 342),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.center()

        let view = SettingsWindow(kiteService: kiteService, onSave: onSave)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView

        self.init(window: window)
    }
}