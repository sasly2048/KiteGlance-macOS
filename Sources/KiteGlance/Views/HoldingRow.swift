import SwiftUI

struct HoldingRow: View {
    /// A plain value, not `@ObservedObject`: `HoldingViewModel` is a struct now,
    /// rebuilt from the portfolio whenever it changes.
    let viewModel: HoldingViewModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // PnL indicator bar
            RoundedRectangle(cornerRadius: 1)
                .fill(viewModel.pnlColor)
                .opacity(0.9)
                .frame(width: 2, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(viewModel.investedDisplay)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(white: 1, opacity: 0.18))
                        .monospacedDigit()

                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color(white: 1, opacity: 0.18))

                    Text(viewModel.currentDisplay)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(white: 1, opacity: 0.3))
                        .monospacedDigit()
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(viewModel.pnlDisplay)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(viewModel.pnlColor)
                    .monospacedDigit()

                Text(viewModel.returnDisplay)
                    .font(.system(size: 10.5))
                    .foregroundStyle(viewModel.pnlColor.opacity(0.7))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isHovered ? Color(white: 1, opacity: 0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .offset(x: isHovered ? 2 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: isHovered)
        .onHover { inside in
            isHovered = inside
        }
        .help(viewModel.tooltip)
    }
}