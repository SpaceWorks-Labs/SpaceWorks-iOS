import XCTest
import Foundation
import SpaceWorksAPI
@testable import SpaceWorks

/// Every DEBUG/demo fixture the app and the tests feed through the generated client must decode
/// with the pinned 0.12.0 types; a stale fixture otherwise surfaces as an unrelated "Couldn't connect".
final class DebugFixtureDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ text: String, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { _ = try decoder.decode(T.self, from: Data(text.utf8)) } catch {
            XCTFail("\(name) does not decode as \(T.self): \(error)", file: file, line: line)
        }
    }

    func testAuthFixturesDecode() {
        decode(Components.Schemas.PublicConfig.self, DebugAuthFixtures.config, "config")
        decode(Components.Schemas.PublicConfig.self, DebugAuthFixtures.nativeConfig(minimum: "2.0.0"), "nativeConfig")
        decode(Components.Schemas.AuthUserPayload.self, DebugAuthFixtures.user, "user")
        decode(Components.Schemas.AuthUserPayload.self, DebugAuthFixtures.staffGrantUser, "staffGrantUser")
        decode(Components.Schemas.AuthUserPayload.self, DebugAuthFixtures.staffPersonUser, "staffPersonUser")
        decode(Components.Schemas.DeviceGrant.self, DebugAuthFixtures.grant, "grant")
        decode(Components.Schemas.DeviceGrant.self, DebugAuthFixtures.staffGrant, "staffGrant")
        decode(Components.Schemas.DeviceLoginResult.self, DebugAuthFixtures.tokens, "tokens")
        decode(Components.Schemas.DeviceLoginResult.self, DebugAuthFixtures.mfa, "mfa")
        decode(Components.Schemas.MemberUsage.self, DebugAuthFixtures.usage, "usage")
        decode(Components.Schemas.Dashboard.self, DebugAuthFixtures.dashboard, "dashboard")
        decode(Components.Schemas.MemberMessaging.self, DebugAuthFixtures.messaging, "messaging")
        decode(Components.Schemas.MFAEnrollment.self, DebugAuthFixtures.enrollment, "enrollment")
    }

    func testMemberAndStaffFixturesDecode() {
        decode(Components.Schemas.TenantBootstrap.self, DebugMemberFixtures.bootstrap, "member bootstrap")
        decode(Components.Schemas.MemberActivity.self, DebugMemberFixtures.activity, "member activity")
        decode(Components.Schemas.MemberCard.self, DebugMemberFixtures.card, "member card")
    }
}
