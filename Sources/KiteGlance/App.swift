import SwiftUI
import AppKit
import KiteGlanceCore
import os.log

@main
struct KiteGlanceApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// `@MainActor` because every member touches AppKit. Under Swift 6's strict
/// concurrency, `NSApplicationDelegate` conformance alone does not confer main
/// actor isolation, so each `NSStatusItem` / window call was an error.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var widgetController: WidgetWindowController?
    private var statusItem: NSStatusItem?
    private let logger = Logger(subsystem: "com.kiteglance", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("KiteGlance starting")

        // Parity with the Windows single-instance mutex: two widgets would fight
        // over the same state file and double every API call. NSRunningApplication
        // is the macOS equivalent -- a second copy defers to the first.
        if isAlreadyRunning() {
            logger.info("Another instance is already running; exiting")
            NSApp.terminate(nil)
            return
        }

        // A leftover API dump from a previous debug session must not outlive it.
        ApiDump.purgeIfDisabled()

        createWidgetWindow()
        setupStatusItem()
        widgetController?.showWindow(nil)
        Task {
            await widgetController?.bootstrap()
            // The account list is only meaningful after bootstrap has resolved
            // it, so the menu is rebuilt once it has.
            await refreshActiveAccount()
            statusItem?.menu = buildStatusMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("KiteGlance shutting down")
        widgetController?.shutdown()
        statusItem = nil
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis", accessibilityDescription: "KiteGlance")
            button.image?.isTemplate = true
        }
        statusItem?.menu = buildStatusMenu()
    }

    /// Also used by the widget's `⋯` button, so the two menus can never drift
    /// apart. Every item targets a selector on this object, so the menu has to be
    /// built here; `target` is set explicitly because a menu shown via `popUp`
    /// is outside the responder chain that the status item relies on.
    func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Show Widget", action: #selector(toggleWidget), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())

        let pinMenu = NSMenu()
        pinMenu.addItem(NSMenuItem(title: "Pin to Desktop", action: #selector(setPinDesktop), keyEquivalent: ""))
        pinMenu.addItem(NSMenuItem(title: "Always on Top", action: #selector(setPinAlwaysOnTop), keyEquivalent: ""))
        pinMenu.addItem(NSMenuItem(title: "Float Freely", action: #selector(setPinNormal), keyEquivalent: ""))
        // NSMenuItem has no `submenu:` initializer; the submenu is assigned
        // after construction.
        let pinItem = NSMenuItem(title: "Pin Mode", action: nil, keyEquivalent: "")
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)

        let backdropMenu = NSMenu()
        backdropMenu.addItem(NSMenuItem(title: "Time of Day", action: #selector(setBackdropTimeOfDay), keyEquivalent: ""))
        backdropMenu.addItem(NSMenuItem(title: "Rotate", action: #selector(setBackdropRotate), keyEquivalent: ""))
        backdropMenu.addItem(NSMenuItem(title: "Graphite (Static)", action: #selector(setBackdropStatic), keyEquivalent: ""))
        backdropMenu.addItem(NSMenuItem.separator())
        backdropMenu.addItem(NSMenuItem(title: "Choose Image…", action: #selector(chooseCustomBackdrop), keyEquivalent: ""))
        let backdropItem = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        backdropItem.submenu = backdropMenu
        menu.addItem(backdropItem)

        // Account switcher. Always shown when any account is known: even
        // with a single account the submenu tells the user *which* one is
        // active, and is the only way to see the active-account tick on a
        // first install (where the Windows original gates it on > 1).
        let accounts = widgetController?.accounts ?? []
        if !accounts.isEmpty {
            let accountMenu = NSMenu()
            for account in accounts {
                let item = NSMenuItem(
                    title: account.label,
                    action: #selector(switchAccount(_:)),
                    keyEquivalent: ""
                )
                // The id travels on the item, so the selector does not have to
                // map a title back to an account.
                item.representedObject = account.id
                item.state = account.id == activeAccountId ? .on : .off
                accountMenu.addItem(item)
            }
            let accountItem = NSMenuItem(title: "Account", action: nil, keyEquivalent: "")
            accountItem.submenu = accountMenu
            menu.addItem(accountItem)
        }

        let themeMenu = NSMenu()
        for mode in ThemeMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(setTheme(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = mode == widgetController?.state.themeMode ? .on : .off
            themeMenu.addItem(item)
        }
        let themeItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // "Open at Login" toggle. Mirrors the Windows `WidgetManager.SetAutostart`
        // menu item. Hidden on macOS 12 and earlier, where `SMAppService.mainApp`
        // is unavailable. The state is read fresh on every build: the
        // registration prompt is system-driven, so the user can change it
        // out from under us via System Settings.
        if LoginLaunchService.isAvailable {
            menu.addItem(NSMenuItem.separator())
            let openAtLogin = NSMenuItem(
                title: "Open at Login",
                action: #selector(toggleOpenAtLogin),
                keyEquivalent: ""
            )
            openAtLogin.state = LoginLaunchService.isEnabled ? .on : .off
            menu.addItem(openAtLogin)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit KiteGlance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Quit stays untargeted so it walks up to NSApp; everything else points
        // at this delegate.
        for item in menu.items + menu.items.compactMap(\.submenu).flatMap(\.items)
        where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }

        // NSMenu renders outside the SwiftUI view tree, so `@Environment(\.palette)`
        // never reaches it. Setting the appearance directly is what themes it.
        if let controller = widgetController {
            let resolved = ResolvedTheme.resolve(
                mode: controller.state.themeMode,
                systemIsDark: NSApp.effectiveAppearance.isDark
            )
            menu.appearance = NSAppearance(named: Palette.of(resolved).appearance)
        }

        return menu
    }

    /// Tracks the resolved active account so the menu can tick it. Refreshed
    /// when the menu is built.
    private var activeAccountId: String?

    func refreshActiveAccount() async {
        activeAccountId = await widgetController?.activeAccountId
    }

    /// Rebuilds the status-bar menu so its tick marks and appearance match the
    /// current theme and active account.
    ///
    /// Assigning a fresh menu is what actually updates it: `refreshActiveAccount`
    /// only sets the variable that `buildStatusMenu` reads.
    func refreshStatusMenu() {
        Task { @MainActor in
            await refreshActiveAccount()
            statusItem?.menu = buildStatusMenu()
        }
    }

    private func createWidgetWindow() {
        widgetController = WidgetWindowController()
    }

    private func isAlreadyRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains { $0 != .current }
    }

    @objc private func toggleWidget() {
        widgetController?.toggleVisibility()
    }

    @objc private func refreshNow() {
        // Throttled to one fetch per 60s; mirrors the Windows RefreshAsync
        // cooldown and shows the "Just synced a moment ago" toast when the
        // user hits the menu item too soon. `R` in the widget itself uses
        // the same path.
        _ = widgetController?.requestManualRefresh()
    }

    @objc private func setPinDesktop() { widgetController?.setPinMode(.desktop) }
    @objc private func setPinAlwaysOnTop() { widgetController?.setPinMode(.alwaysOnTop) }
    @objc private func setPinNormal() { widgetController?.setPinMode(.normal) }

    @objc private func setBackdropTimeOfDay() { widgetController?.setBackdropMode(.timeOfDay) }
    @objc private func setBackdropRotate() { widgetController?.setBackdropMode(.rotate) }
    @objc private func setBackdropStatic() { widgetController?.setBackdropMode(.static) }
    @objc private func chooseCustomBackdrop() { widgetController?.chooseCustomBackdrop() }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // switchToAccount resolves asynchronously and rebuilds this menu when it
        // lands -- reticking here would use the pre-switch answer.
        widgetController?.switchToAccount(id)
    }

    @objc private func setTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ThemeMode(rawValue: raw) else { return }
        // setThemeMode rebuilds the status menu itself, so the tick moves and
        // the menu repaints in the new appearance.
        widgetController?.setThemeMode(mode)
    }

    @objc private func openSettings() {
        widgetController?.showSettings()
    }

    @objc private func toggleOpenAtLogin() {
        // Flip from current state, then rebuild so the tick mark reflects
        // whatever the system actually accepted -- a denied registration
        // prompt is a real failure mode here.
        let newValue = !LoginLaunchService.isEnabled
        LoginLaunchService.setEnabled(newValue)
        refreshStatusMenu()
    }
}

enum PinMode: String, CaseIterable, Codable {
    case normal = "Float Freely"
    case alwaysOnTop = "Always on Top"
    case desktop = "Pin to Desktop"
}

// `BackdropMode` lives in KiteGlanceCore so BackdropService and its tests can
// reach it without importing this executable target.