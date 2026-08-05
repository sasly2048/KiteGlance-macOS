import SwiftUI
import AppKit

struct WidgetView: View {
    @ObservedObject var viewModel: PortfolioViewModel
    let controller: WidgetWindowController

    @State private var currentBackdrop: BackdropImage = .day
    @State private var nextBackdrop: BackdropImage?
    @State private var backdropOpacity: Double = 1
    @State private var scrimOpacity: Double = 0
    @State private var showSkeleton = true
    @State private var breathAnimation = false
    @State private var liveDotColor: Color = .gray
    @State private var toastMessage: String?
    @State private var toastOffset: CGFloat = 8
    @State private var toastOpacity: Double = 0

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
        .onAppear {
            Task { await initialize() }
        }
        .onChange(of: viewModel.expanded) { _, newValue in
            withAnimation(.spring(response: 0.44, dampingFraction: 0.8)) {
                // Height animation handled by window controller
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
                .opacity(0.028)
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
        let color = viewModel.heroColor
        RadialGradient(
            gradient: Gradient(colors: [color.opacity(0.18), .clear]),
            center: .topLeading,
            startRadius: 0,
            endRadius: 400
        )
        .frame(height: 150)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(viewModel.portfolio != nil ? 1 : 0)
        .animation(.easeInOut(duration: 0.7), value: viewModel.portfolio != nil)
    }

    // MARK: - Compact Header

    private var compactHeader: some View {
        HStack {
            Text("Portfolio")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 1, opacity: 0.55))

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

            Text(viewModel.syncLabel)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 1, opacity: 0.3))

            Spacer()

            Button(action: { showMenu() }) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(white: 1, opacity: 0.3))
                    .frame(width: 28, height: 28)
                    .background(Color(white: 1, opacity: 0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { inside in
                // hover effect
            }
        }
        .frame(height: 28)
        .contentShape(Rectangle())
        .gesture(DragGesture().onChanged { _ in controller.handleDrag(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!) })
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.heroLabel)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(white: 1, opacity: 0.3))

                Text(Money.rupees(viewModel.heroValue))
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(viewModel.heroColor)
                    .contentTransition(.numericText())
                    .monospacedDigit()
            }

            Spacer()

            // Percentage chip
            HStack(spacing: 5) {
                Image(systemName: viewModel.heroValue >= 0 ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .rotationEffect(.degrees(viewModel.heroValue >= 0 ? 0 : 180))
                    .animation(.spring(response: 0.46, dampingFraction: 0.8), value: viewModel.heroValue >= 0)

                Text("\(abs(viewModel.heroPct).formatted(.number.precision(.fractionLength(2))))%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(Color(white: 1, opacity: 0.3))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(viewModel.heroColor.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.bottom, 8)
        }
    }

    // MARK: - Track Section

    private var trackSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text(Money.rupees(viewModel.invested))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 1, opacity: 0.3))

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(white: 1, opacity: 0.18))

                Text(Money.rupees(viewModel.currentValue))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)

                Spacer()

                Text(viewModel.activeTab == "funds"
                    ? "\(viewModel.funds.count) fund\(viewModel.funds.count == 1 ? "" : "s")"
                    : Money.signed(viewModel.overallPnl))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(viewModel.activeTab == "funds" ? Color(white: 1, opacity: 0.3) : (viewModel.overallPnl >= 0 ? Color.green : Color.red))
                    .monospacedDigit()
            }

            // Track bar
            GeometryReader { geo in
                let width = geo.size.width
                let center = width / 2
                let invested = viewModel.invested
                let current = viewModel.currentValue

                ZStack(alignment: .leading) {
                    // Track background
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 1, opacity: 0.07))
                        .frame(height: 4)

                    // Delta fill
                    if invested > 0 {
                        let ret = (current / invested - 1) as Decimal
                        let mag = min(abs(ret) / 0.5, 1) as Decimal
                        let half = CGFloat(truncating: mag as NSNumber) * center
                        let isUp = ret >= 0

                        RoundedRectangle(cornerRadius: 2)
                            .fill(isUp ? Color.green : Color.red)
                            .frame(width: max(half, 2), height: 4)
                            .offset(x: isUp ? center : center - half)
                            .animation(.spring(response: 0.8, dampingFraction: 0.8), value: viewModel.currentValue)
                    }

                    // Center notch
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(white: 1, opacity: 0.3))
                        .frame(width: 1.5, height: 10)
                        .offset(x: center - 0.75)
                }
            }
            .frame(height: 10)
        }
    }

    // MARK: - Expander Button

    private var expanderButton: some View {
        Button(action: { controller.toggleExpanded() }) {
            HStack {
                Text(viewModel.expanded ? "Hide" : "Holdings")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color(white: 1, opacity: 0.55))

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(white: 1, opacity: 0.3))
                    .rotationEffect(.degrees(viewModel.expanded ? 180 : 0))
                    .animation(.spring(response: 0.54, dampingFraction: 0.8), value: viewModel.expanded)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
            .background(Color(white: 1, opacity: 0.05))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(white: 1, opacity: 0.08))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
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
                        ForEach(viewModel.holdingsViewModels) { holding in
                            HoldingRow(viewModel: holding)
                                .onTapGesture {
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

    private var tabBar: some View {
        HStack(spacing: 24) {
            tabButton("Stocks", "stocks", viewModel.stocks.count)
            tabButton("Funds", "funds", viewModel.funds.count)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                let tab = viewModel.activeTab == "stocks" ? 0 : 1
                let x = tab == 0 ? 0 : geo.size.width / 2 - 22 // approximate
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 44, height: 2)
                    .offset(x: x)
                    .animation(.spring(response: 0.48, dampingFraction: 0.8), value: viewModel.activeTab)
            }
            .frame(height: 2)
        }
    }

    private func tabButton(_ title: String, _ tab: String, _ count: Int) -> some View {
        Button(action: { controller.switchTab(tab) }) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color(white: 1, opacity: 0.18))
                }
            }
            .foregroundStyle(viewModel.activeTab == tab ? Color.white : Color(white: 1, opacity: 0.3))
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(viewModel.activeTab == "funds" ? "No funds held" : "No stocks held")
                .font(.system(size: 12.5))
                .foregroundStyle(Color(white: 1, opacity: 0.3))
            Text(viewModel.activeTab == "funds" ? "Coin holdings will appear here" : "Equity holdings will appear here")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 1, opacity: 0.18))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Overlay

    private var overlayView: some View {
        ZStack {
            Color(white: 0.07, opacity: 0.95)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text(viewModel.overlayTitle)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)

                Text(viewModel.overlayBody)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(white: 1, opacity: 0.55))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.horizontal, 30)

                Button(action: { viewModel.overlayAction?() }) {
                    Text(viewModel.overlayActionTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .background(
                            LinearGradient(colors: [Color(red: 0x33/255, green: 0x95/255, blue: 1), Color.blue], startPoint: .top, endPoint: .bottom)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
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
                .foregroundStyle(Color.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(Color(white: 0.14, opacity: 0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color(white: 1, opacity: 0.08), lineWidth: 1)
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

    private func showMenu() {
        // Menu is handled by status item
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
        // Load backdrop
        currentBackdrop = BackdropService.pick(mode: controller.state.backdropMode)
        if controller.state.backdropMode == .custom {
            // Custom backdrop will be handled by backdropImage
        }

        // Start breathing animation if market open
        if viewModel.isMarketOpen {
            startBreathing()
            liveDotColor = .blue
        } else {
            liveDotColor = Color(white: 1, opacity: 0.18)
        }

        // Show skeleton initially
        try? await Task.sleep(nanoseconds: 300_000_000)
        withAnimation(.easeOut(duration: 0.34)) {
            showSkeleton = false
        }
    }

    private func startBreathing() {
        breathAnimation = true
    }

    // State access for backdrop
    var state: WidgetState? {
        // Access via controller
        nil
    }
}