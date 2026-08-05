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

        setupStatusItem()
        createWidgetWindow()
        widgetController?.showWindow(nil)
        Task { await widgetController?.bootstrap() }
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
        let pinItem = NSMenuItem(title: "Pin Mode", submenu: pinMenu)
        menu.addItem(pinItem)

        let backdropMenu = NSMenu()
        backdropMenu.addItem(NSMenuItem(title: "Time of Day", action: #selector(setBackdropTimeOfDay), keyEquivalent: ""))
        backdropMenu.addItem(NSMenuItem(title: "Rotate", action: #selector(setBackdropRotate), keyEquivalent: ""))
        backdropMenu.addItem(NSMenuItem(title: "Graphite (Static)", action: #selector(setBackdropStatic), keyEquivalent: ""))
        backdropMenu.addItem(NSMenuItem.separator())
        backdropMenu.addItem(NSMenuItem(title: "Choose Image…", action: #selector(chooseCustomBackdrop), keyEquivalent: ""))
        let backdropItem = NSMenuItem(title: "Background", submenu: backdropMenu)
        menu.addItem(backdropItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit KiteGlance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Quit stays untargeted so it walks up to NSApp; everything else points
        // at this delegate.
        for item in menu.itemArray + menu.itemArray.compactMap(\.submenu).flatMap(\.itemArray)
        where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }

        return menu
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
        Task { await widgetController?.refreshNow() }
    }

    @objc private func setPinDesktop() { widgetController?.setPinMode(.desktop) }
    @objc private func setPinAlwaysOnTop() { widgetController?.setPinMode(.alwaysOnTop) }
    @objc private func setPinNormal() { widgetController?.setPinMode(.normal) }

    @objc private func setBackdropTimeOfDay() { widgetController?.setBackdropMode(.timeOfDay) }
    @objc private func setBackdropRotate() { widgetController?.setBackdropMode(.rotate) }
    @objc private func setBackdropStatic() { widgetController?.setBackdropMode(.static) }
    @objc private func chooseCustomBackdrop() { widgetController?.chooseCustomBackdrop() }

    @objc private func openSettings() {
        widgetController?.showSettings()
    }
}

enum PinMode: String, CaseIterable, Codable {
    case normal = "Float Freely"
    case alwaysOnTop = "Always on Top"
    case desktop = "Pin to Desktop"
}

// `BackdropMode` lives in KiteGlanceCore so BackdropService and its tests can
// reach it without importing this executable target.