// Compact plot of the combined correction response (dB) over a log frequency axis.

import RoomEQCore
import SwiftUI

struct EQCurveGraph: View {
    let controller: AudioEngineController

    /// 200 log-spaced points, 20 Hz…20 kHz.
    private static let frequencies: [Double] = (0..<200).map { 20 * pow(1000, Double($0) / 199) }

    var body: some View {
        // Read here (not inside the Canvas closure) so that the view is
        // refreshed when the curve changes.
        let response = controller.curveResponse(frequencies: Self.frequencies)
        EQCurveCanvas(frequencies: Self.frequencies, response: response, dimmed: !controller.isRunning)
            .frame(height: 110)
            .accessibilityLabel("Grafico della curva di correzione")
    }
}

private struct EQCurveCanvas: View {
    let frequencies: [Double]
    let response: [Double]
    let dimmed: Bool

    private static let gridFrequencies: [(hertz: Double, label: String)] = [
        (20, "20"), (50, "50"), (100, "100"), (200, "200"), (500, "500"),
        (1000, "1k"), (2000, "2k"), (5000, "5k"), (10_000, "10k"), (20_000, "20k"),
    ]
    private static let minFrequency = 20.0
    private static let maxFrequency = 20_000.0

    /// Half height of the y axis: 18 dB, or more (steps of 6 dB) when the
    /// curve goes beyond.
    private var limit: Double {
        let extreme = response.filter(\.isFinite).map(abs).max() ?? 0
        return max(18, (extreme / 6).rounded(.up) * 6)
    }

    var body: some View {
        Canvas { context, size in
            let left: CGFloat = 28
            let right: CGFloat = 10
            let top: CGFloat = 6
            let bottom: CGFloat = 14
            let plot = CGRect(
                x: left, y: top,
                width: max(1, size.width - left - right), height: max(1, size.height - top - bottom))
            let limit = self.limit

            func x(_ hertz: Double) -> CGFloat {
                plot.minX + plot.width * CGFloat(log(hertz / Self.minFrequency) / log(Self.maxFrequency / Self.minFrequency))
            }
            func y(_ decibels: Double) -> CGFloat {
                plot.midY - CGFloat(decibels / limit) * plot.height / 2
            }

            let gridColor = Color.secondary.opacity(0.22)
            let labelFont = Font.system(size: 8).monospacedDigit()

            // Vertical grid + frequency labels.
            for (hertz, label) in Self.gridFrequencies {
                var line = Path()
                line.move(to: CGPoint(x: x(hertz), y: plot.minY))
                line.addLine(to: CGPoint(x: x(hertz), y: plot.maxY))
                context.stroke(line, with: .color(gridColor), lineWidth: 0.5)
                context.draw(
                    Text(label).font(labelFont).foregroundStyle(Color.secondary),
                    at: CGPoint(x: x(hertz), y: plot.maxY + 7), anchor: .center)
            }

            // Horizontal grid every 6 dB (labels every 12 dB when crowded).
            let labelStep = limit > 24 ? 12.0 : 6.0
            for decibels in stride(from: -limit, through: limit, by: 6) {
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y(decibels)))
                line.addLine(to: CGPoint(x: plot.maxX, y: y(decibels)))
                let isZero = abs(decibels) < 0.001
                context.stroke(line, with: .color(isZero ? Color.secondary.opacity(0.55) : gridColor), lineWidth: isZero ? 0.8 : 0.5)
                if decibels.truncatingRemainder(dividingBy: labelStep) == 0 {
                    context.draw(
                        Text(Format.signedNumber(decibels, decimals: 0, plusSign: true))
                            .font(labelFont).foregroundStyle(Color.secondary),
                        at: CGPoint(x: plot.minX - 3, y: y(decibels)), anchor: .trailing)
                }
            }

            // The curve.
            var curve = Path()
            var started = false
            for (hertz, decibels) in zip(frequencies, response) {
                let point = CGPoint(x: x(hertz), y: y(decibels.isFinite ? decibels : 0))
                if started { curve.addLine(to: point) } else { curve.move(to: point); started = true }
            }
            var clipped = context
            clipped.clip(to: Path(plot))
            clipped.stroke(
                curve,
                with: .color(dimmed ? Color.secondary.opacity(0.45) : Color.accentColor),
                style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
