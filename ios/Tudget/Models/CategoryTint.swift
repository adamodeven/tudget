import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

/// The colour a category carries through the whole app -- its ring on the
/// dashboard, its chip in the picker, its tile tint.
///
/// **These values are not a matter of taste.** They're the Okabe-Ito
/// colourblind-safe palette, re-stepped per appearance and checked with a
/// validator rather than by eye. Both sets pass, all pairs:
///
///   - light (surface #FCFCFB): lightness band, chroma floor, normal-vision
///     floor (worst pair ΔE 18.4), CVD separation (worst ΔE 7.6 deutan)
///   - dark  (surface #1C1C1E): same checks, worst normal-vision ΔE 15.6,
///     worst CVD ΔE 6.3 deutan
///
/// Two consequences worth preserving if you ever edit this:
///
/// 1. A CVD separation in the 6–8 band is only legal alongside a second,
///    non-colour channel. Every surface that shows a category shows its emoji
///    and its name too -- colour is never the only thing distinguishing two
///    categories. Don't build a view that breaks that.
/// 2. `neutral` is deliberately grey and deliberately *not* one of the five
///    hues. Six saturated hues cannot all clear the normal-vision floor inside
///    the narrow dark-mode lightness band; five plus a neutral "Other" bucket
///    can. Adding a sixth hue would quietly break the guarantee above.
enum CategoryTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case amber
    case sky
    case green
    case blue
    case mauve
    case neutral

    var id: String { rawValue }

    var label: String {
        switch self {
        case .amber: return "Amber"
        case .sky: return "Sky"
        case .green: return "Green"
        case .blue: return "Blue"
        case .mauve: return "Mauve"
        case .neutral: return "Neutral"
        }
    }

    /// Light-appearance step.
    private var lightHex: UInt32 {
        switch self {
        case .amber: return 0xE69F00
        case .sky: return 0x56B4E9
        case .green: return 0x009E73
        case .blue: return 0x0072B2
        case .mauve: return 0xCC79A7
        case .neutral: return 0x8E8E93
        }
    }

    /// Dark-appearance step. Chosen for the dark surface, not derived by
    /// lightening the light step -- an automatic flip fails the band.
    private var darkHex: UInt32 {
        switch self {
        case .amber: return 0xC18505
        case .sky: return 0x3798CC
        case .green: return 0x008963
        case .blue: return 0x00669F
        case .mauve: return 0xB36290
        case .neutral: return 0x98989F
        }
    }

    var color: Color {
        #if canImport(UIKit)
        Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? darkHex : lightHex)
        })
        #else
        Color(rgb: lightHex)
        #endif
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
#else
private extension Color {
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
#endif
