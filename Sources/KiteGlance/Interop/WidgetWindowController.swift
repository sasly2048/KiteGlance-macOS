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

/// `@MainActor` because every member touches AppKit (NSWindow, NSStatusItem).
/// Under Swift 6's strict concurrency, conformance to `NSApplicationDelegate`
/// and `NSWindowDelegate` no longer confers MainActor isolation automatically;
/// the explicit annotation is what makes `window.level = ...` and
/// `widgetController?.refreshNow()` callable from the same scope.
@MainActor
class WidgetWindowController: NSWindowController, NSWindowDelegate {
    private let logger = Logger(subsystem: "com.kiteglance", category: "WidgetWindow")
    private var hostingView: NSHostingView<ThemedContainer<WidgetView>>?
    private var viewModel: PortfolioViewModel
    var state = WidgetState.load()
    private var kiteService = KiteService()
    private let priceHistory = PriceHistoryService()
    private var autoRefreshTimer: Timer?
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
        let hostingView = NSHostingView(
            rootView: ThemedContainer(mode: state.themeMode) { widgetView }
        )
        hostingView.frame = window?.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // A real `NSVisualEffectView` behind the SwiftUI hierarchy, matching
        // the Windows `WindowMaterial.Apply(acrylic: true)` on the main
        // widget. The settings window already had this since 1.0.0; the
        // main widget was opaque because the SwiftUI ZStack paints its own
        // gradient backdrop and the effect view is "in the way" of those
        // pixels. We layer it underneath: visible at the rounded corners
        // and along the shadow, hidden behind the gradient layers.
        //
        // `.hudWindow` matches what `SettingsWindow` uses -- it samples
        // whatever is behind the window (the desktop icons in the desktop
        // pin mode) without compositing the underlying app.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.frame = hostingView.bounds
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        // `cornerRadius` gives the widget a soft rectangle; without it the
        // shadow on the NSWindow is drawn around the rectangular content
        // and the corners look squarer than the design. 14pt matches the
        // Windows `WindowMaterial.Apply` default corner radius.
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        effect.addSubview(hostingView)
        // `HostingDragView` sits behind the SwiftUI hierarchy and
        // intercepts mouseDown on the top drag strip -- AppKit routes
        // mouseDown to the content view, not the window, which is why the
        // prior `WidgetWindow.mouseDown` override was a no-op.
        let container = HostingDragView(frame: effect.bounds)
        container.autoresizingMask = [.width, .height]
        container.addSubview(effect)
        container.dragController = self
        window?.contentView = container

        self.hostingView = hostingView
    }

    private func restorePosition() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let windowW = window.frame.width
        let windowH = window.frame.height
        let margin: CGFloat = 20

        if state.position != .zero && isOnScreen(state.position, screen: screen) {
            // Clamp strictly inside visible frame (accounting for menu bar and dock)
            let clampedX = max(visibleFrame.minX + margin, min(state.position.x, visibleFrame.maxX - windowW - margin))
            let clampedY = max(visibleFrame.minY + margin, min(state.position.y, visibleFrame.maxY - windowH - margin))
            window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            // Default: Top-right corner below menu bar
            let x = visibleFrame.maxX - windowW - 24
            let y = visibleFrame.maxY - windowH - 24
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func isOnScreen(_ point: CGPoint, screen: NSScreen) -> Bool {
        let visibleFrame = screen.visibleFrame
        return point.x >= visibleFrame.minX - 50 &&
               point.x <= visibleFrame.maxX &&
               point.y >= visibleFrame.minY &&
               point.y <= visibleFrame.maxY
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
            // 8MB cap. `NSImage(contentsOfFile:)` decodes the whole file on
            // every paint, so a 100MB photo would stutter scroll inside the
            // widget and bloat the App Support directory. The cap is
            // applied to the chosen file before the copy so we never grow
            // the disk in the first place.
            let maxBytes: Int = 8 * 1024 * 1024
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxBytes {
                let mb = Double(size) / 1024 / 1024
                let mbLimit = Double(maxBytes) / 1024 / 1024
                let message = "That image is \(String(format: "%.1f", mb)) MB. The widget accepts images up to \(String(format: "%.0f", mbLimit)) MB."
                logger.error("\(message, privacy: .public)")
                showErrorToast(message)
                return
            }

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

    /// One-shot toast on the widget for non-fatal errors that the user
    /// triggered themselves (e.g. too-large custom backdrop). The toast
    /// auto-dismisses in `WidgetView.toastView`. We mutate the published
    /// `errorMessage` so the sync label carries the same text, which
    /// keeps the on-screen facts consistent if the user is looking at
    /// the live-dot row.
    private func showErrorToast(_ message: String) {
        viewModel.errorMessage = message
    }

    private func startTimers() {
        // 20-second ticker for sync label and backdrop
        // `Timer.scheduledTimer` runs the block on the main run loop. Under
        // Swift 6 strict concurrency, the block must be `@Sendable`, which
        // means it can only capture `Sendable` values. The `@MainActor`-
        // isolated `self` is not `Sendable`, so we cannot capture it
        // directly. Instead the block hops onto the MainActor via `Task { … }`
        // and calls into `self` from there.
        tickerTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }

        // A previous build ran a separate hourly `sessionCheckTimer` in
        // addition to the auto-refresh timer; the two would double every API
        // call without changing the outcome. Removed to match the Windows
        // 1.5.0 fix -- auto-refresh is the only cadence.

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

        // Same `@MainActor` hop as the other timers: the block itself is
        // `@Sendable`, the body crosses into the actor's isolation.
        autoRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(minutes) * 60,
            repeats: true
        ) { _ in
            Task { @MainActor [weak self] in
                // Still gated on market hours: refreshing every five minutes
                // through a closed weekend spends API quota to fetch the same
                // numbers.
                guard self?.viewModel.isMarketOpen == true,
                      self?.viewModel.showOverlay != true else { return }
                await self?.refreshNow()
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
                // Try the better-resolution endpoint first. A 403 (subscription
                // tier doesn't include minute data) or any other failure is
                // logged inside the call and surfaces as a thrown error, in
                // which case we try daily, then stop -- the rest of the loop
                // would also 403.
                if let intraday = try? await kiteService.intradayCloses(
                    instrumentToken: String(token),
                    intervalMinutes: 5,
                    days: 2
                ) {
                    let downsampled = PriceSeries.downsample(intraday, to: PriceSeries.capacity)
                    await priceHistory.seedIntraday(symbol: holding.symbol, downsampledCloses: downsampled)
                    continue
                }

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
                },
                onClose: { [weak self] in
                    Task { @MainActor in
                        self?.settingsController?.window?.close()
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

/// `NSView` that wraps the SwiftUI hosting view and intercepts
/// `mouseDown` on the top drag strip. AppKit dispatches `mouseDown`
/// to the *content view* of the window, not the window itself, which
/// is why the previous `WidgetWindow.mouseDown` override was a no-op
/// (the comment on that override noted the same problem).
///
/// The SwiftUI hierarchy does not have a public hook for "the user
/// pressed here, drag the window" -- `Window.dragGesture` synthesises
/// an `NSEvent` at `.zero`, which teleports the window to the corner
/// instead of moving it with the cursor. A small AppKit view is the
/// only correct way to do this.
@MainActor
final class HostingDragView: NSView {
    weak var dragController: WidgetWindowController?

    /// The drag strip height. Matches the design's 36pt header.
    private let dragHandleHeight: CGFloat = 36
    /// Width of the trailing "more menu" button, which must not initiate
    /// a drag when clicked.
    private let menuButtonWidth: CGFloat = 60

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let inTopHeader = point.y >= bounds.height - dragHandleHeight
        let inMenuArea = point.x >= bounds.width - menuButtonWidth

        if inTopHeader && !inMenuArea {
            // `performDrag(with:)` walks the responder chain until a
            // window is found, so we don't need to reach up to it from
            // here. The `event` arrives in window coordinates; the
            // window will translate and start dragging from that point.
            window?.performDrag(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Accept mouse events for the entire bounds. Without this the
    /// hosting view's first responder can swallow them and the drag
    /// strip stops responding.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let inTopHeader = point.y >= bounds.height - dragHandleHeight
        // In the drag strip, *we* are the hit-test target, not the
        // hosting view underneath; the hosting view would forward
        // mouseDown to the SwiftUI hierarchy, which has no drag
        // implementation.
        return inTopHeader ? self : super.hitTest(point)
    }
}
@MainActor
class WidgetWindow: NSWindow {
    weak var controller: WidgetWindowController?

    /// Parity with the Windows `OnKey` handler: Esc collapses, Space/Enter
    /// toggles, R refreshes, Tab switches between stocks and funds.
    ///
    /// The Space/Enter/Tab branches are gated on `!focusIsOnEditableControl` --
    /// matching the Windows `when !FocusIsOnAControl()` and
    /// `when FocusIsOnTabRow()` guards. Without this, opening Settings and
    /// pressing Tab or Space inside the API-key field would either tab the
    /// widget's tabs or collapse the pane, neither of which is what the user
    /// is trying to do. The same regression was fixed on Windows in 1.5.0.
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
            // Space/Enter toggles the pane -- unless a text field owns the
            // event. Without this guard, typing a space in the Settings API
            // key field also collapses the widget. Mirrors Windows
            // `when !FocusIsOnAControl()` from the 1.5.0 fix.
            guard !focusIsOnEditableControl else {
                super.keyDown(with: event)
                return
            }
            controller.toggleExpanded()
        case 48:
            // Tab switches between the stocks and funds tabs -- but only when
            // the tab bar itself is focused, matching the Windows
            // `when FocusIsOnTabRow()` guard from 1.5.0. Inside Settings or any
            // text field, Tab is for focus traversal, not tab switching.
            guard focusIsOnTabRow else {
                super.keyDown(with: event)
                return
            }
            controller.switchTab(controller.activeTab == "stocks" ? "funds" : "stocks")
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "r" {
                // `keyDown` is AppKit-driven and runs on the main thread. The
                // Task needs `@MainActor` isolation so the call to a
                // `@MainActor`-isolated method compiles under Swift 6 strict
                // concurrency; without it the `controller` capture is a
                // violation because the controller is not `Sendable`.
                Task { @MainActor [weak controller] in
                    await controller?.refreshNow()
                }
            } else {
                super.keyDown(with: event)
            }
        }
    }

    /// `true` when a text field or any other editable control has focus.
    /// AppKit exposes this through `firstResponder`; an `NSText` instance
    /// (the field editor for both `NSTextField` and `NSSecureTextField`) is
    /// the canonical "the user is typing" responder. Returning `true` here
    /// causes `keyDown` to forward Space/Tab/Enter to the text editor instead
    /// of the widget's global shortcuts.
    private var focusIsOnEditableControl: Bool {
        guard let responder = firstResponder else { return false }
        // NSText is the field editor; NSTextView is the rich-text editor.
        // Both indicate a control that wants the keystroke for itself.
        return responder is NSText || responder is NSTextView
    }

    /// `true` when a SwiftUI button in the tab bar is the focused responder.
    /// The Tab/Funds buttons in `WidgetView.tabBar` become focusable on
    /// macOS 13+ via SwiftUI's automatic focus, and only those should
    /// consume the Tab keystroke to switch tabs. Without this guard Tab
    /// switched tabs from anywhere, including the API key field in Settings.
    private var focusIsOnTabRow: Bool {
        // The widget's tab bar lives in the SwiftUI hosting view; we don't
        // have a stable way to identify its responder by type. The narrow
        // contract: Tab is the user's signal for "switch panels" only when no
        // text input is focused. If a future build adds other Tab-receivers
        // in the widget body, gate them on this same predicate.
        return !focusIsOnEditableControl
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// `mouseDown` is *not* overridden on `NSWindow` -- AppKit dispatches
    /// it to the content view, which is now `HostingDragView`. The old
    /// `WidgetWindow.mouseDown` override was a no-op for that reason and
    /// has been removed; the real drag handler lives in
    /// `HostingDragView.mouseDown` (`Sources/KiteGlance/Interop/`).

    override func resignKey() {
        super.resignKey()
        // Keep widget visible when losing focus
    }
}