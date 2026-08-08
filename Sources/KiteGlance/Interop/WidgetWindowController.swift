import AppKit
import SwiftUI
import KiteGlanceCore
import os.log

extension NSWindow.Level {
    /// Just above the desktop wallpaper and below the desktop icons -- where a
    /// pinned widget belongs. AppKit ships `.normal`, `.floating`,
    /// `.statusBar` and friends but no `.desktop`; it has to be built from the
    /// CoreGraphics constant. This is the entire macOS answer to the ~250 lines
    /// of WorkerW reparenting in the Windows DesktopPin.cs.
    static let desktopWidget = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
    )
}

class WidgetWindowController: NSWindowController, NSWindowDelegate {
    private let logger = Logger(subsystem: "com.kiteglance", category: "WidgetWindow")
    private var hostingView: NSHostingView<ThemedContainer<WidgetView>>?
    private var viewModel: PortfolioViewModel
    var state = WidgetState.load()
    private var kiteService = KiteService()
    private let priceHistory = PriceHistoryService()
    private var autoRefreshTimer: Timer?
    private var sessionCheckTimer: Timer?
    private var tickerTimer: Timer?
    private var settingsController: SettingsWindowController?
    private var saveDebounce: Task<Void, Never>?

    init() {
        self.viewModel = PortfolioViewModel()

        let window = WidgetWindow(
            contentRect: NSRect(x: 0, y: 0, width: 372, height: 256),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .desktopWidget
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

        // Both assignments pass `self`, so they have to follow super.init.
        window.controller = self
        window.delegate = self
        setupView()
        restorePosition()
        applyPinMode()
        applyAppearance()
        startTimers()
    }

    var customBackdropPath: String? {
        state.customBackdropPath
    }

    var isExpanded: Bool { viewModel.expanded }
    var activeTab: String { viewModel.activeTab }

    required init?(coder: NSCoder) { fatalError() }

    private func setupView() {
        let widgetView = WidgetView(viewModel: viewModel, controller: self)
        hostingView = NSHostingView(
            rootView: ThemedContainer(mode: state.themeMode) { widgetView }
        )
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

    /// Debounced position save, matching the Windows `Debounce(600ms)`. Dragging
    /// emits a continuous stream of frame changes; writing the JSON on each one
    /// would hammer the disk. Without this the position was only persisted at
    /// shutdown, so a crash or force-quit lost it entirely.
    func queueSavePosition() {
        saveDebounce?.cancel()
        saveDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.savePosition()
        }
    }

    /// The macOS counterpart of DesktopPin.cs. Windows needs ~250 lines for this
    /// -- rewriting WINDOWPOS in a WndProc hook, or reparenting into Explorer's
    /// WorkerW -- because there is no window level below the desktop icons.
    /// AppKit exposes exactly that as a level, so the whole feature is these few
    /// assignments.
    func applyPinMode() {
        guard let window else { return }

        // Keeps the widget out of the window menu in every mode, matching
        // WS_EX_TOOLWINDOW on Windows (which also drops it from Alt+Tab).
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = false

        switch state.pinMode {
        case .desktop:
            window.level = .desktopWidget
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .alwaysOnTop:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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

        rebuildAutoRefreshTimer()
    }

    /// (Re)schedules auto-refresh for the configured interval.
    ///
    /// Called whenever the setting changes so a new interval takes effect
    /// immediately -- a preference that needs a restart to apply reads as a bug.
    /// The interval is read through `effectiveRefreshIntervalMinutes`, which
    /// clamps it, so no stored value can schedule a runaway timer.
    func rebuildAutoRefreshTimer() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil

        guard let minutes = state.effectiveRefreshIntervalMinutes else { return }

        autoRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(minutes) * 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                // Still gated on market hours: refreshing every five minutes
                // through a closed weekend spends API quota to fetch the same
                // numbers.
                if self?.viewModel.isMarketOpen == true && self?.viewModel.showOverlay != true {
                    await self?.refreshNow()
                }
            }
        }
    }

    func setRefreshInterval(_ minutes: Int) {
        state.refreshIntervalMinutes = minutes
        state.save()
        rebuildAutoRefreshTimer()
    }

    /// Applies a theme to both worlds: the SwiftUI hierarchy via the palette
    /// environment, and the window itself via `NSAppearance`, which is what
    /// draws the shadow, the titlebar and the menus.
    func setThemeMode(_ mode: ThemeMode) {
        state.themeMode = mode
        state.save()
        applyAppearance()
        setupView()
        // The status menu is built by the app delegate and carries its own
        // appearance and tick marks, neither of which the SwiftUI environment
        // reaches -- without this it stays in the old theme until something
        // else happens to rebuild it.
        rebuildStatusMenu()
    }

    /// Asks the app delegate to rebuild the status-bar menu.
    private func rebuildStatusMenu() {
        (NSApp.delegate as? AppDelegate)?.refreshStatusMenu()
    }

    func applyAppearance() {
        let resolved = ResolvedTheme.resolve(
            mode: state.themeMode,
            systemIsDark: NSApp.effectiveAppearance.isDark
        )
        window?.appearance = NSAppearance(named: Palette.of(resolved).appearance)
    }

    func shutdown() {
        tickerTimer?.invalidate()
        sessionCheckTimer?.invalidate()
        autoRefreshTimer?.invalidate()
        // Cancel the pending debounce first: it would otherwise fire after this
        // final write and race it.
        saveDebounce?.cancel()
        saveDebounce = nil
        savePosition()
    }

    func windowDidMove(_ notification: Notification) {
        queueSavePosition()
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

    /// The two overlays and the actions their buttons perform. Both callbacks are
    /// retained by the view model, which this controller owns, so they capture
    /// `self` weakly to avoid a reference cycle.
    private func promptToConnect() {
        viewModel.showConnectOverlay { [weak self] in
            self?.showSettings()
        }
    }

    private func promptToSignIn(reason: String? = nil) {
        viewModel.showLoginOverlay(reason: reason) { [weak self] in
            Task { @MainActor in await self?.signIn() }
        }
    }

    func bootstrap() async {
        viewModel.activeTab = state.activeTab

        // Point the service at whichever remembered account actually has
        // credentials. `nil` here means every listed account is a bare label,
        // so the only honest outcome is the connect overlay -- signing in with
        // an empty api_key is what produced Kite's error page on Windows.
        if !state.accounts.isEmpty {
            guard let accountId = await resolvedAccountId() else {
                promptToConnect()
                return
            }
            await kiteService.useAccount(accountId)
        }

        // `apiKey` is private to the actor; `hasApiKey()` is the accessor.
        guard await kiteService.hasApiKey() else {
            promptToConnect()
            return
        }

        guard await kiteService.isAuthenticated() else {
            promptToSignIn()
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

            // Every refresh contributes one point per holding; PriceSeries
            // decides whether a given price is worth keeping.
            await priceHistory.record(
                portfolio.holdings
                    .filter { !$0.awaitingPrice }
                    .map { (symbol: $0.symbol, price: $0.lastPrice) }
            )
            await seedHistoricalSeries(for: portfolio.holdings)
            viewModel.priceHistory = await priceHistory.allSeries()
            viewModel.usingStaleNavs = await kiteService.usingStaleFundNavs
            viewModel.errorMessage = nil
            viewModel.hideOverlay()
        } catch let error as KiteError where error.isAuthFailure {
            // Typed, not string-matched: the old `message.contains("expired")`
            // broke the moment Kite reworded its error text.
            promptToSignIn(reason: "Your session expired for the day. Sign in again.")
        } catch {
            viewModel.errorMessage = error.localizedDescription
            if viewModel.lastSync == nil {
                promptToConnect()
            }
        }

        viewModel.isLoading = false
    }

    /// Fills each equity row's series from Kite's historical endpoint, for
    /// accounts that subscribe to it.
    ///
    /// Only for rows the local accumulation has not already filled, and the
    /// service stops asking after the first `PermissionException` -- most
    /// accounts do not pay for this, and that is a normal answer, not an error.
    /// Mutual funds are skipped: there is no historical instrument for a fund.
    private func seedHistoricalSeries(for holdings: [Holding]) async {
        for holding in holdings where !holding.isMutualFund {
            guard let token = holding.instrumentToken,
                  await priceHistory.needsHistoricalSeed(symbol: holding.symbol) else { continue }

            do {
                let closes = try await kiteService.historicalCloses(instrumentToken: String(token))
                await priceHistory.seed(symbol: holding.symbol, closes: closes)
            } catch let error as KiteError where error.isSubscriptionFailure {
                // This account does not pay for historical data. Normal, and the
                // reason the local accumulation exists -- stop asking.
                await priceHistory.markHistoricalUnavailable()
                return
            } catch {
                // One symbol failing is not worth abandoning the rest.
                continue
            }
        }
    }

    func checkSession() async {
        guard viewModel.isMarketOpen else { return }

        if !(await kiteService.isAuthenticated()) {
            promptToSignIn(reason: "Your session expired. Sign in again.")
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
            settingsController = SettingsWindowController(
                kiteService: kiteService,
                refreshIntervalMinutes: state.refreshIntervalMinutes,
                themeMode: state.themeMode,
                onPreferencesChange: { [weak self] minutes, theme in
                    Task { @MainActor in
                        guard let self else { return }
                        self.setRefreshInterval(minutes)
                        self.setThemeMode(theme)
                    }
                },
                onSave: { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        await self.kiteService.reloadCredentials()
                        await self.rememberSignedInAccount()
                        await self.bootstrap()
                    }
                }
            )
            settingsController?.window?.isReleasedWhenClosed = false
        }

        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Accounts

    /// The accounts to show in the menu, and which one is ticked.
    var accounts: [AccountRef] { state.accounts }

    var activeAccountId: String? {
        get async { await resolvedAccountId() }
    }

    /// The active account, resolved against the vault.
    ///
    /// Every read of the active account goes through here rather than reading
    /// `state.activeAccountId` directly. A listed account is a label; only the
    /// Keychain can say whether it has credentials, and `nil` means "none
    /// usable" -- which must lead to the connect overlay, never to silently
    /// using the first listed account with an empty key.
    private func resolvedAccountId() async -> String? {
        var usable: Set<String> = []
        for account in state.accounts
        where await CredentialVault(accountId: account.id).hasStoredCredentials() {
            usable.insert(account.id)
        }

        return state.resolvedAccountId { usable.contains($0) }
    }

    /// Records the Kite user id after a successful sign-in, so the account can
    /// be labelled in the menu.
    ///
    /// Ordering matters: this runs only once credentials are stored, and even
    /// then the menu still resolves through the probe. The label is a
    /// convenience, never evidence.
    func rememberSignedInAccount() async {
        guard let profile = try? await kiteService.currentProfile(),
              let userId = profile.user_id, !userId.isEmpty else { return }

        let label = profile.user_name.flatMap { $0.isEmpty ? nil : $0 } ?? userId

        if let index = state.accounts.firstIndex(where: { $0.id == userId }) {
            state.accounts[index].label = label
        } else {
            state.accounts.append(AccountRef(id: userId, label: label))
        }
        state.activeAccountId = userId
        state.save()
    }

    func switchToAccount(_ id: String) {
        state.activeAccountId = id
        state.save()

        Task { @MainActor in
            // Re-resolve rather than trusting the id just written: if this
            // account has no stored credentials the right outcome is the connect
            // overlay, not a login URL with an empty api_key.
            guard let resolved = await resolvedAccountId() else {
                viewModel.portfolio = nil
                promptToConnect()
                rebuildStatusMenu()
                return
            }

            await kiteService.useAccount(resolved)
            viewModel.portfolio = nil
            await bootstrap()
            // Move the tick to the account that is actually active now.
            rebuildStatusMenu()
        }
    }

    func signIn() async {
        // A second tap while the first login is in flight would try to bind port
        // 5173 again and fail with "port is busy" -- against ourselves. Windows
        // disables the button (`OverlayButton.IsEnabled = false`); this is the
        // same guard.
        guard !viewModel.isSigningIn else { return }
        viewModel.isSigningIn = true
        defer { viewModel.isSigningIn = false }

        viewModel.overlayActionTitle = "Waiting for Kite…"
        do {
            let url = await kiteService.loginURL
            let token = try await LoginServer().captureRequestToken(loginURL: url)
            try await kiteService.authenticate(requestToken: token)
            await rememberSignedInAccount()
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

    /// Pops the status-bar menu under the widget's `⋯` button. The menu is built
    /// by the app delegate because every item targets a selector on it.
    func showContextMenu() {
        guard let delegate = NSApp.delegate as? AppDelegate,
              let contentView = window?.contentView else { return }

        let menu = delegate.buildStatusMenu()
        // Just below the header's trailing edge, where the ⋯ button sits.
        let origin = NSPoint(x: contentView.bounds.maxX - 28, y: contentView.bounds.maxY - 44)
        menu.popUp(positioning: nil, at: origin, in: contentView)
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

    /// Parity with the Windows `OnKey` handler: Esc collapses, Space/Enter
    /// toggles, R refreshes, Tab switches between stocks and funds.
    override func keyDown(with event: NSEvent) {
        guard let controller else {
            super.keyDown(with: event)
            return
        }

        // 53 = Escape, 49 = Space, 36 = Return, 48 = Tab.
        switch event.keyCode {
        case 53:
            if controller.isExpanded { controller.toggleExpanded() } else { super.keyDown(with: event) }
        case 49, 36:
            controller.toggleExpanded()
        case 48:
            controller.switchTab(controller.activeTab == "stocks" ? "funds" : "stocks")
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "r" {
                Task { await controller.refreshNow() }
            } else {
                super.keyDown(with: event)
            }
        }
    }

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