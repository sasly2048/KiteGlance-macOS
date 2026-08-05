import AppKit
import SwiftUI
import os.log

class WidgetWindowController: NSWindowController {
    private let logger = Logger(subsystem: "com.kiteglance", category: "WidgetWindow")
    private var hostingView: NSHostingView<WidgetView>?
    private var viewModel: PortfolioViewModel
    var state = WidgetState.load()
    private var kiteService = KiteService()
    private var autoRefreshTimer: Timer?
    private var sessionCheckTimer: Timer?
    private var tickerTimer: Timer?
    private var settingsController: SettingsWindowController?

    init() {
        self.viewModel = PortfolioViewModel()

        let window = WidgetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 256),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.controller = self
        window.level = .desktop
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)

        setupView()
        restorePosition()
        applyPinMode()
        startTimers()
    }

    var customBackdropPath: String? {
        state.customBackdropPath
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupView() {
        let widgetView = WidgetView(viewModel: viewModel, controller: self)
        hostingView = NSHostingView(rootView: widgetView)
        hostingView?.frame = window?.contentView?.bounds ?? .zero
        hostingView?.autoresizingMask = [.width, .height]
        window?.contentView = hostingView
    }

    private func restorePosition() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame

        if state.position != .zero && isOnScreen(state.position, screen: screen) {
            window.setFrameOrigin(state.position)
        } else {
            let x = visibleFrame.maxX - window.frame.width - 24
            let y = visibleFrame.maxY - 24
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func isOnScreen(_ point: CGPoint, screen: NSScreen) -> Bool {
        let frame = screen.frame
        return point.x >= frame.minX - 40 && point.x <= frame.maxX + 80 &&
               point.y >= frame.minY - 10 && point.y <= frame.maxY + 60
    }

    func savePosition() {
        guard let window else { return }
        state.position = window.frame.origin
        state.save()
    }

    func applyPinMode() {
        guard let window else { return }

        switch state.pinMode {
        case .desktop:
            window.level = .desktop
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.ignoresMouseEvents = false
        case .alwaysOnTop:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        case .normal:
            window.level = .normal
            window.collectionBehavior = [.canJoinAllSpaces]
        }
    }

    func setPinMode(_ mode: PinMode) {
        state.pinMode = mode
        state.save()
        applyPinMode()
    }

    func setBackdropMode(_ mode: BackdropMode) {
        state.backdropMode = mode
        state.save()
    }

    func chooseCustomBackdrop() {
        let panel = NSOpenPanel()
        panel.title = "Choose a background image"
        panel.allowedContentTypes = [.png, .jpeg, .bmp, .webP]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("KiteGlance", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("custom-backdrop\(url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)

            state.customBackdropPath = dest.path
            state.backdropMode = .custom
            state.save()
        }
    }

    private func startTimers() {
        // 20-second ticker for sync label and backdrop
        tickerTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        // Hourly session check
        sessionCheckTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkSession() }
        }

        // Auto-refresh every 5 minutes during market hours
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.viewModel.isMarketOpen == true && self?.viewModel.showOverlay != true {
                    await self?.refreshNow()
                }
            }
        }
    }

    func shutdown() {
        tickerTimer?.invalidate()
        sessionCheckTimer?.invalidate()
        autoRefreshTimer?.invalidate()
        savePosition()
    }

    func toggleVisibility() {
        guard let window else { return }
        if window.isVisible {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func refreshNow() async {
        await fetchPortfolio()
    }

    func bootstrap() async {
        viewModel.activeTab = state.activeTab

        // `apiKey` is private to the actor; `hasApiKey()` is the accessor.
        guard await kiteService.hasApiKey() else {
            viewModel.showConnectOverlay()
            return
        }

        guard await kiteService.isAuthenticated() else {
            viewModel.showLoginOverlay()
            return
        }

        await fetchPortfolio()

        // Restore the expanded pane by driving the same toggle the user would,
        // so the window frame and the view model agree. Setting
        // `viewModel.expanded` here as well would double-toggle and open a
        // previously-expanded widget collapsed.
        if state.isExpanded && !viewModel.expanded {
            toggleExpanded()
        }
    }

    func fetchPortfolio() async {
        viewModel.isLoading = true
        viewModel.errorMessage = nil

        do {
            let portfolio = try await kiteService.getPortfolio()
            viewModel.portfolio = portfolio
            viewModel.lastSync = Date()
            viewModel.usingStaleNavs = await kiteService.usingStaleFundNavs
            viewModel.errorMessage = nil
            viewModel.hideOverlay()
        } catch let error as KiteError where error.isAuthFailure {
            // Typed, not string-matched: the old `message.contains("expired")`
            // broke the moment Kite reworded its error text.
            viewModel.showLoginOverlay(reason: "Your session expired for the day. Sign in again.")
        } catch {
            viewModel.errorMessage = error.localizedDescription
            if viewModel.lastSync == nil {
                viewModel.showConnectOverlay()
            }
        }

        viewModel.isLoading = false
    }

    func checkSession() async {
        guard viewModel.isMarketOpen else { return }

        if !(await kiteService.isAuthenticated()) {
            viewModel.showLoginOverlay(reason: "Your session expired. Sign in again.")
        } else if viewModel.portfolio == nil && !viewModel.showOverlay {
            await fetchPortfolio()
        }
    }

    func toggleExpanded() {
        viewModel.expanded.toggle()
        state.isExpanded = viewModel.expanded
        state.save()

        guard let window else { return }
        let compactHeight: CGFloat = 256
        let rowHeight: CGFloat = 58
        let paneChrome: CGFloat = 76
        let maxPaneHeight: CGFloat = 336

        let rows = max(viewModel.holdingsViewModels.count, 1)
        let paneHeight = min(paneChrome + CGFloat(rows) * rowHeight, maxPaneHeight)
        let targetHeight = viewModel.expanded ? compactHeight + paneHeight : compactHeight

        NSAnimationContext.runAnimationGroup { context in
            context.duration = viewModel.expanded ? 0.64 : 0.48
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1) // Spring-like
            window.animator().setFrame(NSRect(x: window.frame.minX, y: window.frame.minY - (targetHeight - window.frame.height), width: window.frame.width, height: targetHeight), display: true)
        }
    }

    func switchTab(_ tab: String) {
        viewModel.activeTab = tab
        state.activeTab = tab
        state.save()
    }

    func showSettings() {
        // Held for the window's lifetime. A local NSWindowController is
        // deallocated at the end of this method, taking its window with it, so
        // the settings pane would flash and vanish.
        if settingsController == nil {
            settingsController = SettingsWindowController(kiteService: kiteService) { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    await self.kiteService.reloadCredentials()
                    await self.bootstrap()
                }
            }
            settingsController?.window?.isReleasedWhenClosed = false
        }

        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func signIn() async {
        viewModel.overlayActionTitle = "Waiting for Kite…"
        do {
            let url = await kiteService.loginURL
            let token = try await LoginServer().captureRequestToken(loginURL: url)
            try await kiteService.authenticate(requestToken: token)
            viewModel.hideOverlay()
            await fetchPortfolio()
        } catch {
            viewModel.overlayBody = error.localizedDescription
            viewModel.overlayActionTitle = "Try again"
        }
    }

    func handleDrag(_ event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// The view observes `viewModel`, not this controller (an NSWindowController
    /// is not an ObservableObject), so the old `objectWillChange.send()` here
    /// redrew nothing and the "2m ago" label never advanced. Poking a published
    /// property on the view model is what actually invalidates the view.
    private func tick() {
        viewModel.clockTick &+= 1
    }
}

class WidgetWindow: NSWindow {
    weak var controller: WidgetWindowController?

    /// The drag strip along the top of the widget, in points. Everything below
    /// it belongs to SwiftUI.
    private let dragHandleHeight: CGFloat = 44

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The old test asked whether the hit view was the NSHostingView -- which
        // is the entire window -- so every click anywhere, including on buttons
        // and tabs, started a window drag. Only the header strip drags.
        //
        // locationInWindow is bottom-left origin, so the header is the *top*
        // `dragHandleHeight` points of the frame.
        let isInHeader = event.locationInWindow.y >= frame.height - dragHandleHeight

        if isInHeader {
            performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    override func resignKey() {
        super.resignKey()
        // Keep widget visible when losing focus
    }
}