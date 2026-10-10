import Foundation

/// CSS-style cubic-bezier easing (the `bezier-easing` package AMLL uses).
struct KaraokeCubicBezier {
    let x1: Double, y1: Double, x2: Double, y2: Double

    func value(at x: Double) -> Double {
        let x = min(1, max(0, x))
        if x == 0 || x == 1 { return x }
        return sample(y1, y2, solveT(for: x))
    }

    private func sample(_ p1: Double, _ p2: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
    }

    private func slope(_ p1: Double, _ p2: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * p1 + 6 * u * t * (p2 - p1) + 3 * t * t * (1 - p2)
    }

    private func solveT(for x: Double) -> Double {
        var t = x
        for _ in 0..<8 {
            let error = sample(x1, x2, t) - x
            if abs(error) < 1e-6 { return t }
            let d = slope(x1, x2, t)
            if abs(d) < 1e-6 { break }
            t -= error / d
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<30 {
            let value = sample(x1, x2, t)
            if abs(value - x) < 1e-6 { break }
            if value < x { low = t } else { high = t }
            t = (low + high) / 2
        }
        return t
    }
}

/// qplayer's eased syllable lift (TIMER-err/qplayer, LyricRowRenderer.syllableAnimation): a cubic
/// ease-out over the syllable's length, but never quicker than a second. Neighbouring syllables
/// rise over heavily overlapping windows, so the sung part of a line climbs as one smooth ramp
/// instead of each syllable hopping up on its own.
enum KaraokeLift {
    private static let minDurationMs = 1000.0

    static func value(elapsedMs: Double, durationMs: Double) -> Double {
        guard elapsedMs > 0 else { return 0 }
        let x = min(1, elapsedMs / max(minDurationMs, durationMs))
        let remaining = 1 - x
        return 1 - remaining * remaining * remaining
    }
}

/// Per-character emphasis for long held words, after AMLL's
/// packages/core/src/lyric-player/dom/animation/emphasize: each character in turn swells, glows,
/// drifts up and settles back.
struct KaraokeEmphasis {
    let characters: [String]
    /// Scale and push strength.
    let amount: Double
    /// Peak glow alpha, also sizing the glow radius.
    let glow: Double
    /// Length of one character's swell, in ms.
    let durationMs: Double

    private static let swellIn = KaraokeCubicBezier(x1: 0.2, y1: 0.4, x2: 0.58, y2: 1.0)
    private static let swellOut = KaraokeCubicBezier(x1: 0.3, y1: 0.0, x2: 0.58, y2: 1.0)

    /// AMLL emphasizes words held at least a second: any CJK word, otherwise words of 2-7 letters.
    static func make(text: String, durationMs: Int, isLastWord: Bool) -> KaraokeEmphasis? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard durationMs >= 1000 else { return nil }
        if !trimmed.containsCJK {
            guard (2...7).contains(trimmed.count) else { return nil }
        }

        var du = Double(max(1000, durationMs))
        var amount = du / 2000
        amount = amount > 1 ? amount.squareRoot() : pow(amount, 3)
        var glow = du / 3000
        glow = glow > 1 ? glow.squareRoot() : pow(glow, 3)
        amount *= 0.6
        glow *= 0.5
        // The line's last word gets a stronger, longer finish.
        if isLastWord {
            amount *= 1.6
            glow *= 1.5
            du *= 1.2
        }

        let characters = Array(text).map(String.init)
        guard !characters.isEmpty else { return nil }
        return KaraokeEmphasis(characters: characters, amount: min(1.2, amount), glow: min(0.8, glow), durationMs: du)
    }

    struct CharacterState {
        var scale: Double = 1
        /// Offsets in em.
        var offsetX: Double = 0
        var offsetY: Double = 0
        var glowAlpha: Double = 0
        /// Glow radius in em.
        var glowRadius: Double = 0
    }

    func state(forCharacter index: Int, elapsedMs: Double) -> CharacterState {
        let count = Double(characters.count)
        // Characters start one after another across the first 40% of the swell.
        let characterDelay = durationMs / 2.5 / count * Double(index)

        let x = min(1, max(0, (elapsedMs - characterDelay) / durationMs))
        let swell = x < 0.5 ? Self.swellIn.value(at: x / 0.5) : 1 - Self.swellOut.value(at: (x - 0.5) / 0.5)

        // The float leads the glow by 400ms and lasts 1.4x as long.
        let floatX = min(1, max(0, (elapsedMs - characterDelay + 400) / (durationMs * 1.4)))
        let lift = sin(floatX * .pi) * 0.05

        return CharacterState(
            scale: 1 + swell * 0.1 * amount,
            offsetX: -swell * 0.03 * amount * (count / 2 - Double(index)),
            offsetY: -swell * 0.025 * amount - lift,
            glowAlpha: swell * glow,
            glowRadius: min(0.3, glow * 0.3)
        )
    }
}

extension String {
    var containsCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, // Hiragana, Katakana
                 0x3400...0x4DBF, // CJK Extension A
                 0x4E00...0x9FFF, // CJK Unified Ideographs
                 0xAC00...0xD7AF, // Hangul syllables
                 0xF900...0xFAFF, // CJK Compatibility Ideographs
                 0xFF00...0xFFEF: // Fullwidth forms
                return true
            default:
                return false
            }
        }
    }

    /// Rough rendered width in em, for sizing the soft edge of the fill without measuring text.
    var estimatedWidthEm: Double {
        unicodeScalars.reduce(0) { width, scalar in
            String(scalar).containsCJK ? width + 1 : width + 0.55
        }
    }
}
