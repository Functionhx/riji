import SwiftUI

#if canImport(AppKit)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

// 纸与墨（docs/DESIGN.md §4.1）。浅色 / 深色两套，跟随系统外观。

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
        #else
        self.init(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
        #endif
    }
}

extension PlatformColor {
    convenience init(hex: UInt32) {
        let hasAlpha = hex > 0xFFFFFF
        let a = hasAlpha ? CGFloat(hex & 0xFF) / 255 : 1
        let rgb = hasAlpha ? hex >> 8 : hex
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
    }
}

public enum Ink {
    public static let paper = Color(light: 0xFAF8F3, dark: 0x141413)
    public static let paper2 = Color(light: 0xF2EFE7, dark: 0x1C1B19)
    public static let ink = Color(light: 0x1D1C1A, dark: 0xF3F0E8)
    public static let ink2 = Color(light: 0x55524A, dark: 0xB5B1A6)
    public static let ink3 = Color(light: 0x8F8B80, dark: 0x7D796F)
    public static let line = Color(light: 0xE6E2D8, dark: 0x2D2B27)
    public static let ochre = Color(light: 0xB5762A, dark: 0xD79A4E)
    public static let ochreSoft = Color(light: 0xEAD2AD, dark: 0x5A4428)
    public static let selection = Color(light: 0xE6E1D4, dark: 0x2A2925)

    public static func sticky(_ name: String) -> Color {
        switch name {
        case "pink": Color(light: 0xF6D7D9, dark: 0x4B3035)
        case "mint": Color(light: 0xD6ECDF, dark: 0x27433A)
        case "blue": Color(light: 0xD9E6F6, dark: 0x2B3A4E)
        default: Color(light: 0xF8EAA6, dark: 0x4A4327)
        }
    }

    public static let stickyInk = Color(light: 0x3A372C, dark: 0xEFE9D6)
    public static let tape = Color(light: 0xDAD1BAA6, dark: 0xFFFFFF29)

    public static func heat(_ level: Int) -> Color {
        switch level {
        case 1: Color(light: 0xD9D2BF, dark: 0x3A362C)
        case 2: Color(light: 0xB9AE8F, dark: 0x6B6148)
        case 3: Color(light: 0x8A7D5A, dark: 0xA8996F)
        case 4: Color(light: 0x4F4632, dark: 0xE9DCB4)
        default: Color(light: 0xECE8DE, dark: 0x22211E)
        }
    }
}

public enum Typeface {
    /// 宋体标题；没有宋体的系统退回衬线设计。
    public static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        #if os(macOS)
        if NSFont(name: "Songti SC", size: size) != nil { return .custom("Songti SC", size: size).weight(weight) }
        #endif
        return .system(size: size, weight: weight, design: .serif)
    }

    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static func body(_ size: CGFloat = 15, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// Spark 便利贴的手写体（楷体）；没有就用衬线。
    public static func hand(_ size: CGFloat) -> Font {
        #if os(macOS)
        for name in ["LXGW WenKai", "Kaiti SC", "STKaiti"] where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        #endif
        return .system(size: size, design: .serif)
    }
}

/// 等宽小标签：字距 0.14em、全大写。
struct Eyebrow: View {
    var text: String
    var color: Color = Ink.ink3
    var size: CGFloat = 11

    var body: some View {
        Text(text.uppercased())
            .font(Typeface.mono(size))
            .tracking(size * 0.14)
            .foregroundStyle(color)
    }
}

/// 等宽字符进度条：▓▓▓▓░░░░░
struct GlyphMeter: View {
    var fraction: Double
    var cells: Int = 9

    var body: some View {
        let filled = Int((fraction * Double(cells)).rounded())
        let done = Text(String(repeating: "▓", count: filled)).foregroundStyle(Ink.ink)
        let rest = Text(String(repeating: "░", count: max(0, cells - filled))).foregroundStyle(Ink.ink3)
        Text("\(done)\(rest)")
            .font(Typeface.mono(11))
            .tracking(-0.5)
    }
}
