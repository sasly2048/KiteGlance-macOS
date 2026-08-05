import SwiftUI
import AppKit
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

    private func buildStatusMenu() -> NSMenu {
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

        return menu
    }

    private func createWidgetWindow() {
        widgetController = WidgetWindowController()
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

enum BackdropMode: String, CaseIterable, Codable {
    case timeOfDay = "Time of Day"
    case rotate = "Rotate"
    /// `static` is a Swift keyword, so the case name needs backticks.
    case `static` = "Graphite (Static)"
    case custom = "Custom"
}