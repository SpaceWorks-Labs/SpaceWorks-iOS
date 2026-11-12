import XCTest
import Foundation
import SpaceWorksAPI
@testable import SpaceWorks

/// 0.12.0 payloads (Fixtures/Contract, validated against the pinned schema by the Python suite)
/// that the 0.9.2 client failed to decode, read through the generated client and URLProtocol stubs.
final class ContractDecodingTests: XCTestCase {
    private let json = ["Content-Type": "application/json"]

    static func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Fixtures/Contract/\(name).json"))
    }

    private func service(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) -> SpaceWorksService {
        StubProtocol.lock.lock(); StubProtocol.handler = handler; StubProtocol.lock.unlock()
        let config = DeviceSession.configuration(); config.protocolClasses = [StubProtocol.self]
        return SpaceWorksService(origin: try! ServerOrigin("https://spaceworks.example"), session: DeviceSession.make(configuration: config),
                                 initialTokens: TokenPair(access: "member-access", refresh: "member-refresh"), appVersion: "1.4.0",
                                 staffStorage: MemoryStaffGrantStorage(.init(pair: TokenPair(access: "staff-access", refresh: "staff-refresh"),
                                                                             makerspaceID: 7, makerspaceSlug: "fab-lab-kochi")))
    }
    override func tearDown() { StubProtocol.lock.lock(); StubProtocol.handler = nil; StubProtocol.lock.unlock() }

    func testMemberPayloadsWithNewEnumValuesDecodeAsTheirRawValues() async throws {
        let client = service { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer member-access")
            let path = request.url!.path
            let name: String
            switch path {
            case "/api/v1/auth/me": name = "me"
            case "/api/v1/bootstrap": name = "bootstrap"
            case "/api/v1/public/fab-lab-kochi/spaces": name = "spaces"
            case "/api/v1/public/fab-lab-kochi/inventory": name = "inventory"
            case "/api/v1/member/makerspaces/7/payments": name = "payments"
            case "/api/v1/member/makerspaces/7/payment-documents": name = "documents"
            case "/api/v1/notifications/preferences/7": name = "preferences"
            default: XCTFail("Unexpected route \(path)"); name = "me"
            }
            return (200, self.json, try Self.fixture(name))
        }
        try await client.makerspace.select(7, activeMemberships: [7])
        let me = try await client.me()
        XCTAssertEqual(me.session_authority.value1, "member")
        XCTAssertEqual(me.event_grants?.first?.permissions, ["judge", "mentor_queue", "check_in"])
        try await client.withMakerspace(7) {
            let bootstrap = try await client.memberBootstrap(slug: "fab-lab-kochi")
            XCTAssertEqual(bootstrap.makerspace.request_access, "contact")
            let spaces = try await client.memberSpaces(slug: "fab-lab-kochi")
            XCTAssertEqual(spaces.first?.kind.value1, "machine")
            let inventory = try await client.memberInventory(slug: "fab-lab-kochi", page: 1, search: "", category: nil)
            XCTAssertEqual(inventory.results.first?.availability?.label, "Lent at events only")
            let payments = try await client.memberPayments(makerspaceID: 7)
            XCTAssertEqual(payments.first?.subject_type, "loan_rental")
            let documents = try await client.memberPaymentDocuments(makerspaceID: 7, page: 1)
            XCTAssertEqual(documents.results.first?.kind, "bill")
            let preferences = try await client.communicationPreferences(id: 7)
            XCTAssertEqual(preferences.cells.first?.feature, "presence")
        }
    }

    func testStaffPayloadsNullableMembershipAndOptionalCheckInFieldsDecode() async throws {
        let client = service { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer staff-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Makerspace-Id"), "7")
            switch request.url!.path {
            case "/api/v1/admin/makerspaces/7/spaces": return (200, self.json, try Self.fixture("admin_spaces"))
            case "/api/v1/admin/makerspace/7/direct-loan-members": return (200, self.json, try Self.fixture("direct_members"))
            case "/api/v1/admin/events/801/check-in/resolve":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
                XCTAssertEqual(body, ["checkin_token": "71000000-0000-4000-8000-000000000009"])
                return (200, self.json, try Self.fixture("checkin"))
            case "/api/v1/admin/bookings/1001/reject":
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
                XCTAssertEqual(body, ["reason": "The room is closed for maintenance."])
                return (200, self.json, Data(DebugStaffFixtures.booking.utf8))
            default: XCTFail("Unexpected route \(request.url!.path)"); return (404, self.json, Data("{}".utf8))
            }
        }
        let staff = await client.staffRefresh.snapshot()
        try await client.withStaffGrant(expectedCredentials: staff, makerspaceID: 7) {
            let spaces = try await client.staffSpaces(makerspaceID: 7, page: 1)
            XCTAssertEqual(spaces.results.first?.kind.value1, "machine")
            let members = try await client.staffDirectMembers(makerspaceID: 7, page: 1)
            XCTAssertNil(members.results.first?.membership_id)
            XCTAssertEqual(members.results.first?.is_guest_pass, true)
            let resolved = try await client.staffResolveCheckIn(eventID: 801, body: .init(checkin_token: "71000000-0000-4000-8000-000000000009"))
            XCTAssertNil(resolved.event_status); XCTAssertNil(resolved.payment_status)
            _ = try await client.staffRejectBooking(id: 1001, reason: "The room is closed for maintenance.")
        }
    }

    func testDeviceGrantListFollowsThePageEnvelope() async throws {
        var pages: [String?] = []
        let client = service { request in
            XCTAssertEqual(request.url!.path, "/api/v1/auth/device/grants")
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            pages.append(page)
            var envelope = try JSONSerialization.jsonObject(with: try Self.fixture("grants")) as! [String: Any]
            if page == "1" { envelope["next"] = "https://spaceworks.example/api/v1/auth/device/grants?page=2"; envelope["count"] = 3 }
            else { envelope["results"] = [(envelope["results"] as! [Any])[0]]; envelope["previous"] = "https://spaceworks.example/api/v1/auth/device/grants?page=1"; envelope["count"] = 3 }
            return (200, self.json, try JSONSerialization.data(withJSONObject: envelope))
        }
        let grants = try await client.withSession { try await client.accountGrants() }
        XCTAssertEqual(pages, ["1", "2"])
        XCTAssertEqual(grants.count, 3)
        XCTAssertEqual(grants[1].authority, "staff"); XCTAssertEqual(grants[1].staff_makerspace_id, 7)
    }

    func testParityOperationsRescheduleRequestStatusAndCardName() async throws {
        let token = "a8a33ab0-c138-4c0a-85eb-fdcb6b75318f"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let client = service { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer member-access")
            switch (request.httpMethod, request.url!.path) {
            case ("POST", "/api/v1/public/fab-lab-kochi/my-bookings/\(token)/reschedule"):
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
                XCTAssertEqual(Set(body.keys), ["starts_at", "ends_at"])
                let fixture = try JSONSerialization.jsonObject(with: Data(DebugMemberFixtures.bookings.utf8)) as! [String: Any]
                return (200, self.json, try JSONSerialization.data(withJSONObject: (fixture["results"] as! [Any])[0]))
            case ("GET", "/api/v1/public/requests/\(token)/status"):
                return (200, self.json, Data(#"{"status":"accepted","created_at":"2026-11-01T09:00:00Z","items":[]}"#.utf8))
            case ("PATCH", "/api/v1/member/makerspaces/7/member-card"):
                let body = try JSONSerialization.jsonObject(with: requestBody(request)) as! [String: String]
                XCTAssertEqual(body, ["printed_name": "Meera N."])
                var card = try JSONSerialization.jsonObject(with: Data(DebugMemberFixtures.card.utf8)) as! [String: Any]
                card["printed_name"] = "Meera N."; card.removeValue(forKey: "qr_image")
                return (200, self.json, try JSONSerialization.data(withJSONObject: card))
            default: XCTFail("Unexpected route \(request.url!.path)"); return (404, self.json, Data("{}".utf8))
            }
        }
        try await client.makerspace.select(7, activeMemberships: [7])
        try await client.withMakerspace(7) {
            _ = try await client.rescheduleMemberBooking(slug: "fab-lab-kochi", token: token, start: start, end: start.addingTimeInterval(3600))
            let status = try await client.memberRequestStatus(token: token)
            XCTAssertEqual(status.status, "accepted")
            let card = try await client.updateMemberCard(id: 7, printedName: "Meera N.")
            XCTAssertEqual(card.printed_name, "Meera N.")
        }
    }
}
