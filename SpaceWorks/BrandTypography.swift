import SwiftUI
import UIKit

/// Design-Kit 0.12.0 typography with open-licensed (OFL) faces only: Outfit for interface text,
/// Outfit ExtraBold (800) for display headings, Outfit Light (300) for light display text and
/// Unbounded for one short accent phrase per screen.
///
/// Both kit fonts are variable fonts whose named instances carry no PostScript names, so a face is
/// the registered family's default font plus a `wght` axis value, never an instance name.
enum BrandTypography {
    struct Face: Equatable {
        /// PostScript name of the registered variable font's default instance.
        let base: String
        let weight: Int
        static func outfit(_ weight: Int) -> Face { Face(base: "Outfit-Thin", weight: weight) }
        static func unbounded(_ weight: Int) -> Face { Face(base: "Unbounded-Regular", weight: weight) }
    }
    enum Weight: CaseIterable {
        case light, regular, medium, semibold, bold
        /// Outfit `wght` for interface text; Bold Text moves to a heavier instance.
        func face(boldText: Bool) -> Face {
            let weights = [300, 400, 500, 600, 700, 800]
            let index = Self.allCases.firstIndex(of: self)!
            return .outfit(weights[boldText ? [2, 3, 4, 4, 5][index] : index])
        }
    }
    static let displayStyles: Set<Font.TextStyle> = [.largeTitle, .title, .title2]
    static func face(_ style: Font.TextStyle, weight: Weight, boldText: Bool) -> Face {
        if displayStyles.contains(style) {
            if weight == .bold { return .outfit(800) }
            if weight == .light && !boldText { return .outfit(300) }
        }
        return weight.face(boldText: boldText)
    }
    static func size(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }
    static func textStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
    /// The registered variable font at an exact `wght`; refuses a silent system fallback.
    static func uiFont(_ face: Face, size: CGFloat) -> UIFont {
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(name: face.base, size: size).addingAttributes([variation: [0x77676874: face.weight]])
        let font = UIFont(descriptor: descriptor, size: size)
        guard font.fontName.hasPrefix(face.base.split(separator: "-")[0]) else { preconditionFailure("Missing registered Space Works font") }
        return font
    }
    /// A Dynamic Type scaled face for SwiftUI; `BrandFont` recomputes it when the text size changes.
    static func font(_ style: Font.TextStyle, weight: Weight, boldText: Bool, sizeCategory: UIContentSizeCategory = .large) -> Font {
        scaled(face(style, weight: weight, boldText: boldText), size: size(style), style: style, sizeCategory: sizeCategory)
    }
    static func scaled(_ face: Face, size: CGFloat, style: Font.TextStyle, sizeCategory: UIContentSizeCategory) -> Font {
        let traits = UITraitCollection(preferredContentSizeCategory: sizeCategory)
        return Font(UIFontMetrics(forTextStyle: textStyle(style)).scaledFont(for: uiFont(face, size: size), compatibleWith: traits))
    }
    /// The single Unbounded accent phrase of a layout; never body copy.
    static func accent(_ style: Font.TextStyle = .title2, size: CGFloat = 24, sizeCategory: UIContentSizeCategory = .large) -> Font {
        scaled(.unbounded(500), size: size, style: style, sizeCategory: sizeCategory)
    }
    static func unscaledFont(size: CGFloat, weight: Weight = .regular, boldText: Bool = false) -> UIFont {
        uiFont(weight.face(boldText: boldText), size: size)
    }
    static func uiFont(style: UIFont.TextStyle = .body, weight: Weight = .regular,
                       traits: UITraitCollection, boldText: Bool) -> UIFont {
        let base = UIFontDescriptor.preferredFontDescriptor(withTextStyle: style,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)).pointSize
        let font = unscaledFont(size: base, weight: weight, boldText: boldText)
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font, compatibleWith: traits)
    }
}

extension DynamicTypeSize {
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

private struct BrandFont: ViewModifier {
    var style: Font.TextStyle
    var weight: BrandTypography.Weight
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func body(content: Content) -> some View {
        content.font(BrandTypography.font(style, weight: weight, boldText: legibilityWeight == .bold,
                                          sizeCategory: dynamicTypeSize.contentSizeCategory))
    }
}

private struct AccentFont: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func body(content: Content) -> some View {
        content.font(BrandTypography.accent(sizeCategory: dynamicTypeSize.contentSizeCategory))
    }
}

extension View {
    func brandFont(_ style: Font.TextStyle, weight: BrandTypography.Weight? = nil) -> some View {
        modifier(BrandFont(style: style, weight: weight ?? (style == .headline ? .semibold : .regular)))
    }
    /// The one Unbounded accent phrase of a screen, scaled with Dynamic Type.
    func brandAccent() -> some View { modifier(AccentFont()) }
}
