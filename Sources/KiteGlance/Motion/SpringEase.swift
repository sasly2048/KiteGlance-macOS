import Foundation
import CoreGraphics
import QuartzCore
import SwiftUI

// Spring physics for layout animations
struct Spring {
    let stiffness: Double
    let damping: Double
    let mass: Double = 1.0

    static let layout = Spring(stiffness: 170, damping: 20)
    static let gentle = Spring(stiffness: 130, damping: 22)
    static let snap = Spring(stiffness: 320, damping: 24)

    func solve(t: Double) -> Double {
        let m = max(mass, 0.0001)
        let w0 = sqrt(stiffness / m)
        let zeta = damping / (2 * sqrt(stiffness * m))

        if zeta < 1 {
            // Underdamped - overshoots slightly
            let wd = w0 * sqrt(1 - zeta * zeta)
            let x = exp(-zeta * w0 * t) * (cos(wd * t) + zeta * w0 / wd * sin(wd * t))
            return 1 - x
        } else {
            // Critically damped
            let x = exp(-w0 * t) * (1 + w0 * t)
            return 1 - x
        }
    }
}

// `SpringAnimation` (a VectorArithmetic conformance) was removed: nothing
// referenced it, and it could not compile -- `VectorArithmetic` requires
// `AdditiveArithmetic`, whose operators must produce a value from `zero` alone,
// which its `let spring` / `let duration` stored properties made impossible.
// SwiftUI's built-in `.spring(response:dampingFraction:)` covers every use here.

// Quartic ease-out for number animations (no overshoot)
struct QuarticEase {
    static func ease(_ t: Double) -> Double {
        1 - pow(1 - t, 4)
    }
}

// Number tweening system
@MainActor
class NumeralTween: ObservableObject {
    struct Tween {
        var from: Decimal
        var to: Decimal
        var elapsed: Double = 0
        var duration: Double
        let format: (Decimal) -> String
        var currentText: String

        init(from: Decimal, to: Decimal, duration: Double, format: @escaping (Decimal) -> String) {
            self.from = from
            self.to = to
            self.duration = duration
            self.format = format
            self.currentText = format(from)
        }
    }

    private var tweens: [ObjectIdentifier: Tween] = [:]
    private var displayLink: CADisplayLink?

    @MainActor static let shared = NumeralTween()

    /// The display link starts on first use rather than in `init`. A
    /// `@MainActor`-isolated initializer cannot be called from the nonisolated
    /// context that initializes a `static let`, and a link that ticks with no
    /// tweens registered just burns a wakeup every frame.
    private init() {}

    private func startIfNeeded() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Stops the link once nothing is animating, so an idle widget does not hold
    /// the CPU awake at display refresh rate.
    private func stopIfIdle() {
        guard tweens.isEmpty, displayLink != nil else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = link.duration
        var completed: [ObjectIdentifier] = []

        for (id, var tween) in tweens {
            tween.elapsed += dt
            let progress = min(tween.elapsed / tween.duration, 1.0)
            let eased = QuarticEase.ease(progress)
            let value = tween.from + (tween.to - tween.from) * Decimal(eased)
            tween.currentText = tween.format(value)

            if progress >= 1 {
                tween.currentText = tween.format(tween.to)
                tween.from = tween.to
                completed.append(id)
            }

            tweens[id] = tween
        }

        for id in completed {
            tweens.removeValue(forKey: id)
        }

        objectWillChange.send()
        stopIfIdle()
    }

    func animate(_ target: AnyObject, from: Decimal, to: Decimal, duration: Double = 0.72, format: @escaping (Decimal) -> String) {
        startIfNeeded()
        let id = ObjectIdentifier(target)
        if let existing = tweens[id] {
            let current = existing.from + (existing.to - existing.from) * Decimal(QuarticEase.ease(min(existing.elapsed / existing.duration, 1.0)))
            tweens[id] = Tween(from: current, to: to, duration: duration, format: format)
        } else {
            tweens[id] = Tween(from: from, to: to, duration: duration, format: format)
        }
    }

    func currentText(for target: AnyObject) -> String? {
        tweens[ObjectIdentifier(target)]?.currentText
    }

    func reset(_ target: AnyObject) {
        tweens.removeValue(forKey: ObjectIdentifier(target))
    }
}