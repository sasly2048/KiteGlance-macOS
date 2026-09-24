import SwiftUI
import AppKit
import KiteGlanceCore

struct WidgetView: View {
    @ObservedObject var viewModel: PortfolioViewModel
    let controller: WidgetWindowController

    @State private var currentBackdrop: BackdropImage = .day
    @State private var nextBackdrop: BackdropImage?
    @State private var backdropOpacity: Double = 1
    @State private var scrimOpacity: Double = 0
    @State private var breathAnimation = false
    @State private var liveDotColor: Color = .gray
    @State private var toastMessage: String?
    @State private var toastOffset: CGFloat = 8
    @State private var toastOpacity: Double = 0
    /// The skeleton overlay is up while this is true. Set to true on first
    /// launch and flipped to false by `initialize()` after a 300ms hold, so
    /// the first paint reads as "loading" rather than a blank widget. The
    /// skeleton view itself is rendered in `body` via `if showSkeleton`.
    @State private var showSkeleton = true
    /// Drives the holdings-row stagger. Flipped true once the pane is open so
    /// the rows animate in rather than appearing all at once.
    @State private var rowsVisible = false
    /// Tracks the x-offset of the active tab underline bar.
    @State private var tabUnderlineX: CGFloat = 20
    @State private var tabUnderlineWidth: CGFloat = 44
    /// Index of the currently keyboard-focused row in the holdings list.
    /// `nil` when the list is not focused. The arrow keys move this up and
    /// down; `Enter` copies the row's ticker to the clipboard (matching
    @Environment(\.palette) private var palette

    private let compactHeight: CGFloat = 256
    private let rowHeight: CGFloat = 58
    private let paneChrome: CGFloat = 76
    private let maxPaneHeight: CGFloat = 336

    var body: some View {
        ZStack {
            // Backdrop layers
            backdropLayer
            grainOverlay
            topSheen
            accentWash

            // Skeleton overlay while the first paint has not yet committed.
            // Matches the Windows MainWindow.xaml `Bone` style: a faux hero
            // number and two faux track rows that fade out in 340ms once
            // `initialize()` has handed control back to the live layout.
            if showSkeleton {
                skeletonOverlay
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                // Compact header
                compactHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)

                // Hero values
                heroSection
                    .padding(.horizontal, 20)

                // Invested -> Current track
                trackSection
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                // Expander button
                expanderButton
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                // Holdings pane
                if viewModel.expanded {
                    holdingsPane
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: 372)
            .clipped()

            // Overlay
            if viewModel.showOverlay {
                overlayView
            }

            // Toast
            if let toastMessage {
                toastView(toastMessage)
            }
        }
        .frame(width: 372, height: viewModel.expanded ? compactHeight + paneHeight : compactHeight)
        .background(Color.clear)
        .task { await initialize() }
        // The controller's 20-second timer bumps `clockTick`; the sync label and
        // the backdrop are both wall-clock derived, so this is what makes them
        // advance.
        .onChange(of: viewModel.clockTick) { _, _ in
            refreshBackdrop()
        }
        // Rows stage in after the pane opens and clear instantly when it closes,
        // so a reopen replays the stagger from the start.
        .onChange(of: viewModel.expanded) { _, isExpanded in
            if isExpanded {
                rowsVisible = true
            } else {
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { rowsVisible = false }
            }
        }
        // A failed refresh with data on screen: flip the live dot to amber so
        // the user can see the portfolio is stale, not just be told in the
        // sync label. Mirrors the Windows `MainWindow.LiveDot.Opacity` reset
        // on error.
        .onChange(of: viewModel.isStale) { _, isStale in
            withAnimation(.easeInOut(duration: 0.32)) {
                liveDotColor = isStale
                    ? .orange
                    : (viewModel.isMarketOpen ? .blue : palette.faint)
            }
        }
    }

    private var paneHeight: CGFloat {
        let rows = max(viewModel.holdingsViewModels.count, 1)
        return min(paneChrome + CGFloat(rows) * rowHeight, maxPaneHeight)
    }

    // MARK: - Backdrop

    @ViewBuilder
    private var backdropLayer: some View {
        if let next = nextBackdrop {
            backdropImage(next)
                .opacity(backdropOpacity)
        }
        backdropImage(currentBackdrop)
            .opacity(nextBackdrop == nil ? 1 : 1 - backdropOpacity)

        // Darkening scrim, applied only over user-supplied images. `scrimOpacity`
        // was previously declared and never rendered; the multiplier `* 0.35`
        // here used to cap the scrim to 35% of the desired value, so a
        // fully-on custom image was only 35% darkened -- the labels could
        // still wash out. Match the Windows `BackdropScrim` crossfade:
        // `scrimOpacity` 1.0 means full scrim, 0.0 means none.
        Color.black
            .opacity(scrimOpacity)
            .allowsHitTesting(false)

        // The eight backdrops are dark-tuned raster art. Light mode washes them
        // toward white instead of commissioning a second set of eight -- the
        // shapes still read through, and the labels above get the bright ground
        // they need.
        palette.backdropTint
            .opacity(palette.backdropTintOpacity)
            .allowsHitTesting(false)
    }

    /// `.custom` is a `BackdropMode`, not a `BackdropImage` -- the old
    /// `image == .custom` compared across two unrelated enums. Whether to use
    /// the user's file is a property of the *mode*, so it is decided here.
    private func backdropImage(_ image: BackdropImage) -> some View {
        Group {
            if controller.state.backdropMode == .custom,
               let customPath = controller.customBackdropPath,
               let nsImage = NSImage(contentsOfFile: customPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if let nsImage = Assets.backdrop(image) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // No asset on disk: fall back to the mesh gradient rather than
                // rendering an empty rectangle.
                image.fallbackGradient
            }
        }
        .frame(width: 372, height: viewModel.expanded ? compactHeight + paneHeight : compactHeight)
        .clipped()
    }

    @ViewBuilder
    private var grainOverlay: some View {
        if let grain = Assets.grain {
            Image(nsImage: grain)
                .resizable(resizingMode: .tile)
                .frame(width: 372, height: viewModel.expanded ? compactHeight + paneHeight : compactHeight)
                .opacity(palette.grainOpacity)
                .blendMode(.overlay)
        }
    }

    private var topSheen: some View {
        LinearGradient(
            colors: [.clear, .white.opacity(0.15), .clear],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var accentWash: some View {
        // The `let` above the gradient made this a multi-statement body with no
        // `return`, so it inferred nothing and failed to compile.
        RadialGradient(
            gradient: Gradient(colors: [viewModel.heroColor(palette).opacity(0.18), .clear]),
            center: .topLeading,
            startRadius: 0,
            endRadius: 400
        )
        .frame(height: 150)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(viewModel.portfolio != nil ? 1 : 0)
        // Two consecutive `.animation` modifiers compose as "last wins"; the
        // earlier duration of 0.7s on `portfolio != nil` was being dropped
        // and only the 0.5s on `heroValue >= 0` applied. Merge the two
        // triggers into a single tuple so both transitions run at the same
        // duration the user actually sees.
        .animation(.easeInOut(duration: 0.5), value: AnimationValues(
            hasPortfolio: viewModel.portfolio != nil,
            heroNonNegative: viewModel.heroValue >= 0
        ))
    }

    /// Animatable pair for `accentWash`. Using a struct keeps SwiftUI's
    /// `.animation(value:)` happy with a single Equatable token while still
    /// responding to either input change.
    private struct AnimationValues: Equatable {
        let hasPortfolio: Bool
        let heroNonNegative: Bool
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        HStack {
            Text("Portfolio")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondary)

            // Live indicator
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 10, height: 10)
                    .scaleEffect(breathAnimation ? 1.0 : 0.4)
                    .opacity(breathAnimation ? 0.28 : 0)
                    .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: false), value: breathAnimation)

                Circle()
                    .fill(liveDotColor)
                    .frame(width: 5, height: 5)
                    .opacity(viewModel.isMarketOpen ? 1 : 0.5)
            }
            .frame(width: 10, height: 10)
            .padding(.leading, 10)
            // The pulse conveys "market open" purely through animation, which
            // VoiceOver cannot perceive. This is the same fact as text.
            .accessibilityElement()
            .accessibilityLabel(viewModel.marketStatusDescription)

            Text(viewModel.syncLabel)
                .font(.system(size: 11))
                .foregroundStyle(palette.tertiary)
                .accessibilityLabel("Last updated")
                .accessibilityValue(viewModel.syncLabel)

            Spacer()

            Button(action: { showMenu() }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.tertiary)
                    .frame(width: 28, height: 28)
                    .background(palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Widget menu")
            .onHover { inside in
                // hover effect
            }
        }
        .frame(height: 28)
        // No drag gesture here: `WidgetWindow.mouseDown` already drags the header
        // strip using the real event. The gesture this replaced synthesised an
        // NSEvent at `location: .zero`, which teleported the window to the corner
        // of the screen instead of moving it with the cursor.
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.heroLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.tertiary)

                // 720ms on the hero, 640ms elsewhere, matching the Windows
                // Numeral tween durations.
                Text(Money.rupees(viewModel.heroValue))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(viewModel.heroColor(palette))
                    .contentTransition(.numericText())
                    .monospacedDigit()
                    .animation(.easeOut(duration: 0.72), value: viewModel.heroValue)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(viewModel.heroLabel)
            .accessibilityValue(viewModel.heroAccessibilityValue)

            Spacer()

            // Percentage chip
            HStack(spacing: 5) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(viewModel.heroValue >= 0 ? 0 : 180))
                    .animation(.spring(response: 0.46, dampingFraction: 0.8), value: viewModel.heroValue >= 0)

                Text(viewModel.heroPctDisplay) // already includes % (Money.percent)
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.72), value: viewModel.heroPct)
            }
            .foregroundStyle(palette.tertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(viewModel.heroColor(palette).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.bottom, 8)
            // The hero value already announces this percentage; repeating it
            // makes VoiceOver read the same number twice.
            .accessibilityHidden(true)
        }
    }

    // MARK: - Track Section

    private var trackSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text(Money.rupees(viewModel.invested))
                    .font(.system(size: 12))
                    .foregroundStyle(palette.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.64), value: viewModel.invested)

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(palette.faint)

                Text(Money.rupees(viewModel.currentValue))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.64), value: viewModel.currentValue)

                Spacer()

                Text(viewModel.activeTab == "funds"
                    ? "\(viewModel.funds.count) fund\(viewModel.funds.count == 1 ? "" : "s")"
                    : Money.signed(viewModel.overallPnl))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.activeTab == "funds" ? palette.tertiary : (viewModel.overallPnl >= 0 ? palette.positive : palette.negative))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    // Keyed on the tab too, so switching tabs cuts rather than
                    // counting from a rupee total to a fund count -- two
                    // unrelated facts. Windows calls Numeral.Reset here for the
                    // same reason.
                    .animation(.easeOut(duration: 0.64), value: viewModel.overallPnl)
                    .animation(nil, value: viewModel.activeTab)
            }

            .accessibilityElement(children: .combine)
            .accessibilityLabel("Invested versus current value")

            // Track bar
            GeometryReader { geo in
                let width = geo.size.width
                let center = width / 2
                let invested = viewModel.invested
                let current = viewModel.currentValue

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(palette.surfaceHover)
                        .frame(height: 4)

                    // Delta fill
                    if invested > 0 {
                        let ret = (current / invested - 1) as Decimal
                        let mag = min(abs(ret) / 0.5, 1) as Decimal
                        let half = CGFloat(truncating: mag as NSNumber) * center
                        let isUp = ret >= 0

                        RoundedRectangle(cornerRadius: 2)
                            .fill(isUp ? palette.positive : palette.negative)
                            .frame(width: max(half, 2), height: 4)
                            .offset(x: isUp ? center : center - half)
                            .animation(.spring(response: 0.8, dampingFraction: 0.8), value: viewModel.currentValue)
                    }

                    // Center notch
                    RoundedRectangle(cornerRadius: 1)
                        .fill(palette.tertiary)
                        .frame(width: 1.5, height: 10)
                        .offset(x: center - 0.75)
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Expander Button

    private var expanderButton: some View {
        Button(action: { controller.toggleExpanded() }) {
            HStack {
                Text(viewModel.expanded ? "Hide" : "Holdings")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.secondary)

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.tertiary)
                    .rotationEffect(.degrees(viewModel.expanded ? 180 : 0))
                    .animation(.spring(response: 0.54, dampingFraction: 0.8), value: viewModel.expanded)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(palette.surface)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(palette.hairline)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Holdings")
        .accessibilityValue(viewModel.expanded ? "Expanded" : "Collapsed")
        .accessibilityHint(viewModel.expanded ? "Double-tap to hide holdings" : "Double-tap to show holdings")
    }

    // MARK: - Holdings Pane

    private var holdingsPane: some View {
        VStack(spacing: 0) {
            // Tab bar
            tabBar

            // Holdings list
            ScrollView {
                LazyVStack(spacing: 1) {
                    if viewModel.holdingsViewModels.isEmpty {
                        emptyState
                    } else {
                        // Rows arrive top-down, 26ms apart, floating up 10pt and
                        // settling -- the Windows StaggerIn timing. SwiftUI does
                        // this with a per-row animation delay; no walking of item
                        // containers needed.
                        ForEach(Array(viewModel.holdingsViewModels.enumerated()), id: \.element.id) { index, holding in
                            HoldingRow(
                                viewModel: holding,
                                series: viewModel.priceHistory[holding.rawSymbol],
                                isSelected: Binding(
                                    get: { viewModel.selectedRowIndex == index },
                                    set: { newValue in
                                        viewModel.selectedRowIndex = newValue ? index : nil
                                    }
                                )
                            )
                                .opacity(rowsVisible ? 1 : 0)
                                .offset(y: rowsVisible ? 0 : 10)
                                .animation(
                                    .spring(response: 0.52, dampingFraction: 0.95)
                                        .delay(rowsVisible ? Double(index) * 0.026 : 0),
                                    value: rowsVisible
                                )
                                .onTapGesture {
                                    viewModel.selectedRowIndex = index
                                    copyToPasteboard(holding.rawSymbol)
                                    showToast("Copied \(holding.symbol)")
                                }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .padding(.trailing, 11) // scrollbar space
            }
            .mask(
                LinearGradient(
                    colors: [.clear, .black, .black, .clear],
                    startPoint: .top, endPoint: .bottom
                )
            )
        }
    }

    private var tabBar: some View {\r
        HStack(spacing: 24) {\r
            tabButton("Stocks", "stocks", viewModel.stocks.count)\r
                .background(\r
                    GeometryReader { geo in\r
                        Color.clear.preference(\r
                            key: TabFrameKey.self,\r
                            value: ["stocks": geo.frame(in: .named("tabBar"))]\r
                        )\r
                    }\r
                )\r
            tabButton("Funds", "funds", viewModel.funds.count)\r
                .background(\r
                    GeometryReader { geo in\r
                        Color.clear.preference(\r
                            key: TabFrameKey.self,\r
                            value: ["funds": geo.frame(in: .named("tabBar"))]\r
                        )\r
                    }\r
                )\r
            Spacer()\r
        }\r
        .padding(.horizontal, 20)\r
        .padding(.top, 14)\r
        .coordinateSpace(name: "tabBar")\r
        .onPreferenceChange(TabFrameKey.self) { frames in\r
            let tab = viewModel.activeTab\r
            if let frame = frames[tab] {\r
                withAnimation(.spring(response: 0.48, dampingFraction: 0.8)) {\r
                    tabUnderlineX = frame.minX\r
                    tabUnderlineWidth = max(frame.width, 30)\r
                }\r
            }\r
        }\r
        .overlay(alignment: .bottomLeading) {\r
            Rectangle()\r
                .fill(palette.primary)\r
                .frame(width: tabUnderlineWidth, height: 2)\r
                .offset(x: tabUnderlineX)\r
                .animation(.spring(response: 0.48, dampingFraction: 0.8), value: viewModel.activeTab)\r
        }\r
    }\r
\r
    private func tabButton(_ title: String, _ tab: String, _ count: Int) -> some View {\r
        Button(action: { controller.switchTab(tab) }) {\r
            HStack(spacing: 6) {\r
                Text(title)\r
                    .font(.system(size: 11.5, weight: .semibold))\r
                if count > 0 {\r
                    Text("\(count)")\r
                        .font(.system(size: 11.5, weight: .semibold))\r
                        .foregroundStyle(palette.faint)\r
                }\r
            }\r
            .foregroundStyle(viewModel.activeTab == tab ? palette.primary : palette.tertiary)\r
            .padding(.vertical, 10)\r
        }\r
        .buttonStyle(.plain)\r
        .accessibilityLabel(title)\r
        .accessibilityValue(count > 0 ? "\(count) held" : "None held")\r
        .accessibilityAddTraits(viewModel.activeTab == tab ? [.isSelected, .isButton] : .isButton)\r
    }\r

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(viewModel.activeTab == "funds" ? "No funds held" : "No stocks held")
                .font(.system(size: 12.5))
                .foregroundStyle(palette.tertiary)
            Text(viewModel.activeTab == "funds" ? "Coin holdings will appear here" : "Equity holdings will appear here")
                .font(.system(size: 11))
                .foregroundStyle(palette.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Skeleton

    /// Renders a faint placeholder layout while the first portfolio fetch
    /// is in flight. Mirrors the Windows MainWindow.xaml `Bone` style:
    /// a faux hero number, two faux track rows, that crossfade out in
    /// 340ms once `initialize()` flips `showSkeleton` to `false`.
    private var skeletonOverlay: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(palette.surface)
                    .frame(width: 80, height: 12)
                Spacer()
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.surface)
                    .frame(width: 48, height: 18)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            RoundedRectangle(cornerRadius: 6)
                .fill(palette.surface)
                .frame(width: 200, height: 36)
                .padding(.horizontal, 20)
                .padding(.top, 12)

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.surface)
                    .frame(height: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.surface)
                    .frame(height: 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Overlay

    private var overlayView: some View {
        ZStack {
            palette.overlayScrim
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text(viewModel.overlayTitle)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primary)

                Text(viewModel.overlayBody)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 30)

                Button(action: { viewModel.overlayAction?() }) {
                    Text(viewModel.overlayActionTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.primary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(
                            LinearGradient(colors: [Color(red: 0x33/255, green: 0x95/255, blue: 1), Color.blue], startPoint: .top, endPoint: .bottom)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .opacity(viewModel.isSigningIn ? 0.5 : 1)
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isSigningIn)
            }
            .padding(30)
        }
        .transition(.opacity)
    }

    // MARK: - Toast

    private func toastView(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(palette.toastBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(palette.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .shadow(radius: 8)
                .offset(y: toastOffset)
                .opacity(toastOpacity)
                .onAppear {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                        toastOffset = 0
                        toastOpacity = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) {
                        withAnimation(.easeOut(duration: 0.34)) {
                            toastOffset = 8
                            toastOpacity = 0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                            self.toastMessage = nil
                        }
                    }
                }
        }
        .padding(.bottom, 18)
    }

    // MARK: - Actions

    /// Presents the same menu as the status-bar item. Was previously an empty
    /// stub, so the `⋯` button did nothing.
    private func showMenu() {
        controller.showContextMenu()
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func showToast(_ message: String) {
        toastMessage = message
        toastOffset = 8
        toastOpacity = 0
    }

    private func initialize() async {
        // First paint lands instantly -- a 1.2s dissolve from nothing on launch
        // would read as a glitch. Windows passes `instant: true` here too.
        currentBackdrop = BackdropService.pick(mode: controller.state.backdropMode)
        scrimOpacity = controller.state.backdropMode == .custom ? 1 : 0

        // Stale: amber dot (the "Cannot reach Kite" state). Closed: gray.
        // Open: blue with a breath pulse.
        if viewModel.isStale {
            liveDotColor = .orange
        } else if viewModel.isMarketOpen {
            startBreathing()
            liveDotColor = .blue
        } else {
            liveDotColor = palette.faint
        }

        // Show skeleton initially
        // `.milliseconds` not `nanoseconds:` -- the nanoseconds parameter was
        // deprecated in macOS 13 and the new form takes a typed Duration
        // matching the rest of Swift's duration API.
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.easeOut(duration: 0.34)) {
            showSkeleton = false
        }
    }

    /// Re-picks the backdrop for the current clock. Driven by the controller's
    /// 20-second tick, so the widget actually walks through the day instead of
    /// keeping whatever image it launched with.
    func refreshBackdrop() {
        let picked = BackdropService.pick(mode: controller.state.backdropMode)
        // A user-supplied photo gets a darkening scrim so text contrast holds;
        // the built-in gradients are already tuned dark and get none. Same rule
        // as the Windows ApplyBackdrop.
        let wantsScrim: Double = controller.state.backdropMode == .custom ? 1 : 0

        guard picked != currentBackdrop || wantsScrim != scrimOpacity else { return }

        // 1200ms ease-in-out: dusk should arrive as a dissolve, not a cut.
        withAnimation(.easeInOut(duration: 1.2)) {
            currentBackdrop = picked
            scrimOpacity = wantsScrim
        }
    }

    private func startBreathing() {
        breathAnimation = true
    }
}