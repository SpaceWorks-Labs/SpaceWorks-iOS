import CoreText
import SwiftUI
import XCTest
@testable import SpaceWorks

@MainActor final class BrandTypographyTests: XCTestCase {
    /// Variable faces report their named instance through the `wght` axis.
    nonisolated private func weight(_ font: UIFont) -> Int? {
        (CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber])?[NSNumber(value: 0x77676874)]?.intValue
    }

    func testAllKitFacesLoadWithoutSystemFallbackAndContainInterfaceGlyphs() throws {
        for (face, family) in [(BrandTypography.Face.outfit(300), "Outfit"), (.outfit(400), "Outfit"), (.outfit(500), "Outfit"), (.outfit(600), "Outfit"),
                               (.outfit(700), "Outfit"), (.outfit(800), "Outfit"), (.unbounded(500), "Unbounded")] {
            let font = BrandTypography.uiFont(face, size: 17)
            XCTAssertTrue(font.fontName.hasPrefix(family), "\(face) resolved to \(font.fontName)")
            XCTAssertEqual(weight(font), face.weight, "\(face)")
            let characters = Array("Space Works 0123456789".utf16)
            var glyphs = Array(repeating: CGGlyph(), count: characters.count)
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font as CTFont, characters, &glyphs, characters.count), "\(face)")
            XCTAssertFalse(glyphs.contains(0), "\(face)")
        }
    }

    func testDisplayHeadingsUseOutfitDisplayWeightsAndInterfaceTextUsesOutfit() {
        XCTAssertEqual(BrandTypography.face(.largeTitle, weight: .bold, boldText: false), .outfit(800))
        XCTAssertEqual(BrandTypography.face(.title2, weight: .bold, boldText: true), .outfit(800))
        XCTAssertEqual(BrandTypography.face(.title, weight: .light, boldText: false), .outfit(300))
        XCTAssertEqual(BrandTypography.face(.title, weight: .light, boldText: true), .outfit(500))
        XCTAssertEqual(BrandTypography.face(.body, weight: .bold, boldText: false), .outfit(700))
        XCTAssertEqual(BrandTypography.face(.headline, weight: .semibold, boldText: false), .outfit(600))
        XCTAssertEqual(BrandTypography.face(.caption, weight: .regular, boldText: true), .outfit(600))
    }

    func testUIKitMetricsScaleActualOutfitFromDefaultToLargestAccessibilityCategory() {
        let normal = BrandTypography.uiFont(traits: UITraitCollection(preferredContentSizeCategory: .large), boldText: false)
        let enlarged = BrandTypography.uiFont(traits: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), boldText: false)
        XCTAssertEqual(normal.familyName, "Outfit")
        XCTAssertEqual(weight(normal), 400)
        XCTAssertEqual(weight(enlarged), 400)
        XCTAssertGreaterThan(enlarged.pointSize, normal.pointSize * 2)
        XCTAssertGreaterThan(enlarged.lineHeight, normal.lineHeight)
    }

    func testNativeLegibilityTraitUsesRealHeavierInstanceAndKeepsAccessibilityScaling() {
        // This is an explicit native trait test, not a claim that the OS Bold Text setting changed.
        let traits = UITraitCollection(traitsFrom: [UITraitCollection(legibilityWeight: .bold),
            UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)])
        let font = BrandTypography.uiFont(traits: traits, boldText: traits.legibilityWeight == .bold)
        XCTAssertEqual(weight(font), 600)
        XCTAssertGreaterThan(font.pointSize, 34)
        let heading = BrandTypography.uiFont(style: .headline, weight: .semibold, traits: traits, boldText: true)
        XCTAssertEqual(weight(heading), 700)
    }

    func testPasswordRepresentableRefreshesFontWhenSwiftUITypeAndLegibilityChange() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let password = "Synthetic font test"
        let host = UIHostingController(rootView: AnyView(PasswordEntry(text: .constant(password), identifier: "brand-password")
            .dynamicTypeSize(.large).environment(\.legibilityWeight, .regular)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        func field(in view: UIView) -> UITextField? {
            if let field = view as? UITextField { return field }
            return view.subviews.compactMap { field(in: $0) }.first
        }
        host.view.layoutIfNeeded()
        let input = try XCTUnwrap(field(in: host.view))
        let original = try XCTUnwrap(input.font)
        XCTAssertEqual(weight(original), 400)
        XCTAssertEqual(input.text, password)
        host.rootView = AnyView(PasswordEntry(text: .constant(password), identifier: "brand-password")
            .dynamicTypeSize(.accessibility5).environment(\.legibilityWeight, .bold))
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        let fontUpdated = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in (object as? UITextField)?.font.map { self.weight($0) == 600 } ?? false }, object: input)
        await fulfillment(of: [fontUpdated], timeout: 2)
        host.view.layoutIfNeeded()
        let retained = try XCTUnwrap(field(in: host.view))
        XCTAssertTrue(retained === input)
        XCTAssertEqual(retained.text, password)
        let updated = try XCTUnwrap(retained.font)
        XCTAssertEqual(weight(updated), 600)
        XCTAssertGreaterThan(updated.pointSize, original.pointSize * 2)
    }
}
