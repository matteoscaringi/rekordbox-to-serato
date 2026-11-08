import Foundation

/// Serato DJ Pro hot cue colours.
///
/// Serato writes one value into the file ("stored") but shows a different colour on screen
/// ("displayed"). The two palettes below line up index by index. They come from Mixxx's
/// reverse-engineered tables (src/util/color/predefinedcolorpalettes.cpp, GPL).
public enum SeratoCueColor: Int, CaseIterable {
    // Named after what Serato DJ Pro shows on screen (index-aligned with the tables below).
    case red, redOrange, orange, yellow, green, darkGreen, brightGreen, lime, navy,
         cyan, skyBlue, royalBlue, blue, violet, purple, pink, crimson, darkRed

    /// Value written into Serato Markers2.
    public var stored: RGB { RGB(hex: Self.storedHex[rawValue]) }
    /// Colour Serato DJ Pro shows for that value.
    public var displayed: RGB { RGB(hex: Self.displayedHex[rawValue]) }

    static let storedHex: [UInt32] = [
        0xCC0000, 0xCC4400, 0xCC8800, 0xCCCC00, 0x88CC00, 0x44CC00, 0x00CC00, 0x00CC44, 0x00CC88,
        0x00CCCC, 0x0088CC, 0x0044CC, 0x0000CC, 0x4400CC, 0x8800CC, 0xCC00CC, 0xCC0088, 0xCC0044,
    ]
    static let displayedHex: [UInt32] = [
        0xC02626, 0xDB4E27, 0xF8821A, 0xFAC313, 0x4EB648, 0x006838, 0x1FAD26, 0x8DC63F, 0x2B3673,
        0x1DBEBD, 0x0F88CA, 0x16308B, 0x173BA2, 0x5C3F97, 0x6823B6, 0xCE359E, 0xDC1D49, 0xC71136,
    ]

    /// The Serato colour that *looks* closest to `color`, compared with what Serato displays.
    ///
    /// CIEDE2000 with kL = 2 (its standard setting for de-emphasising lightness): Serato's
    /// palette is darker and more muted than rekordbox's, so hue should decide, not brightness.
    /// That maps rekordbox red → red, green → green, purple → purple, orange → orange, etc.
    public static func closest(to color: RGB) -> SeratoCueColor {
        let target = Lab(color)
        func d(_ c: SeratoCueColor) -> Double { Lab.deltaE2000(target, Lab(c.displayed), kL: 2) }
        return allCases.min { d($0) < d($1) }!
    }

    /// The colour Serato shows for a stored value (unknown values are shown as-is).
    public static func displayed(forStored c: RGB) -> RGB {
        storedHex.firstIndex(of: UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b))
            .map { RGB(hex: displayedHex[$0]) } ?? c
    }
}

/// CIE L*a*b* (D65) and the CIEDE2000 colour difference.
struct Lab {
    let L: Double, a: Double, b: Double

    init(_ c: RGB) {
        func lin(_ v: UInt8) -> Double {
            let x = Double(v) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = lin(c.r), g = lin(c.g), bl = lin(c.b)
        let X = (0.4124564 * r + 0.3575761 * g + 0.1804375 * bl) / 0.95047
        let Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl
        let Z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * bl) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(X), fy = f(Y), fz = f(Z)
        L = 116 * fy - 16; a = 500 * (fx - fy); b = 200 * (fy - fz)
    }

    static func deltaE2000(_ p: Lab, _ q: Lab, kL: Double = 1, kC: Double = 1, kH: Double = 1) -> Double {
        let d2r = Double.pi / 180
        let c1 = hypot(p.a, p.b), c2 = hypot(q.a, q.b)
        let cBar7 = pow((c1 + c2) / 2, 7)
        let g = 0.5 * (1 - sqrt(cBar7 / (cBar7 + pow(25, 7))))
        let a1 = (1 + g) * p.a, a2 = (1 + g) * q.a
        let c1p = hypot(a1, p.b), c2p = hypot(a2, q.b)
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / d2r
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(p.b, a1), h2 = hue(q.b, a2)
        let dL = q.L - p.L, dC = c2p - c1p
        var dh = 0.0
        if c1p * c2p != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * sqrt(c1p * c2p) * sin(dh / 2 * d2r)
        let lBar = (p.L + q.L) / 2, cBarP = (c1p + c2p) / 2
        var hBar = h1 + h2
        if c1p * c2p != 0 {
            hBar = abs(h1 - h2) <= 180 ? (h1 + h2) / 2 : (h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2)
        }
        let t = 1 - 0.17 * cos((hBar - 30) * d2r) + 0.24 * cos(2 * hBar * d2r)
            + 0.32 * cos((3 * hBar + 6) * d2r) - 0.20 * cos((4 * hBar - 63) * d2r)
        let dTheta = 30 * exp(-pow((hBar - 275) / 25, 2))
        let cBarP7 = pow(cBarP, 7)
        let rc = 2 * sqrt(cBarP7 / (cBarP7 + pow(25, 7)))
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / sqrt(20 + pow(lBar - 50, 2))
        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin(2 * dTheta * d2r) * rc
        let l = dL / (kL * sl), c = dC / (kC * sc), h = dH / (kH * sh)
        return sqrt(l * l + c * c + h * h + rt * c * h)
    }
}
