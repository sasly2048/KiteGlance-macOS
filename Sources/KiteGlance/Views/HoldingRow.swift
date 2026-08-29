import SwiftUI
import KiteGlanceCore

struct HoldingRow: View {
    /// A plain value, not `@ObservedObject`: `HoldingViewModel` is a struct now,
    /// rebuilt from the portfolio whenever it changes.
    let viewModel: HoldingViewModel
    /// The recent price window for this symbol. Empty until enough refreshes
    /// have accumulated, which is why the sparkline is conditional.
    var series: PriceSeries = PriceSeries()

    /// `true` while this row is the focused keyboard target. Bound by
    /// `WidgetView` so the focused row can render a selection ring
    /// matching the Windows ListBox highlight.
    @Binding var isSelected: Bool

    @State private var isHovered = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            // PnL indicator bar
            RoundedRectangle(cornerRadius: 1)
                .fill(viewModel.pnlColor(palette))
                .opacity(0.9)
                .frame(width: 2, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(palette.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(viewModel.investedDisplay)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.faint)
                        .monospacedDigit()

                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(palette.faint)

                    Text(viewModel.currentDisplay)
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.tertiary)
                        .monospacedDigit()
                }
            }

            Spacer()

            if series.isRenderable {
                Sparkline(series: series, palette: palette)
                    .frame(width: 46, height: 20)
                    // The line repeats the numbers either side of it, so it is
                    // decoration to VoiceOver rather than a fifth thing to read.
                    .accessibilityHidden(true)
            }

            VStack(alignment: .trailing, spacing: 4) {
                Text(viewModel.pnlDisplay)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(viewModel.pnlColor(palette))
                    .monospacedDigit()

                Text(viewModel.returnDisplay)
                    .font(.system(size: 10.5))
                    .foregroundStyle(viewModel.pnlColor(palette).opacity(0.7))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isSelected ? palette.surfaceHover
                      : isHovered ? palette.surfaceHover.opacity(0.5)
                                   : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .offset(x: isHovered ? 2 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isHovered)
        .onHover { inside in
            isHovered = inside
        }
        .help(viewModel.tooltip)
        // Without this the row reads as four unlabelled numbers in a row --
        // "INFY", "12,400", "13,010", "+610", "+4.92%" -- with no indication of
        // what any of them are. Combined, it is one sentence.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(viewModel.symbol)
        .accessibilityValue(viewModel.accessibilityValue)
        .accessibilityHint("Double-tap to copy the symbol")
        // Focus the row so the widget can navigate with arrow keys
        // (parity with the Windows ListBox). SwiftUI gives Buttons an
        // intrinsic focusable element; an HStack would not.
        .focusable()
        .focusEffectDisabled()
    }
}

/// The recent price window as a line, scaled to its own range.
///
/// Deliberately a `Path` rather than a Swift Charts `LineMark`: this is a 46pt
/// sparkline with no axes, labels, legend or interaction, and Charts would add
/// a plot area, gesture recognisers and layout passes for every row in the
/// list. The whole shape is four lines of geometry.
struct Sparkline: View {
    let series: PriceSeries
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            let points = series.normalised()

            Path { path in
                for (index, point) in points.enumerated() {
                    let position = CGPoint(
                        x: point.x * geo.size.width,
                        y: point.y * geo.size.height
                    )
                    if index == 0 {
                        path.move(to: position)
                    } else {
                        path.addLine(to: position)
                    }
                }
            }
            .stroke(
                // The series' own direction, not the holding's lifetime P&L: a
                // stock still down overall but recovering today draws a rising
                // green line, and colouring it red would contradict the shape
                // immediately above it.
                series.isRising ? palette.positive : palette.negative,
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )
            .opacity(0.85)
        }
    }
}
