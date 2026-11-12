"""The 0.12.0 contract payloads must satisfy the authoritative schema (closed enums included)."""
import json
import test_staff_fixtures


class ContractFixturesTests(test_staff_fixtures.StaffFixturesTests):
    directory = "Contract"
    models = {
        "me": "AuthUserPayload", "me_staff": "AuthUserPayload", "me_handle_required": "AuthUserPayload",
        "bootstrap": "TenantBootstrap", "inventory": "PaginatedPublicProductList",
        "spaces": {"type": "array", "items": {"$ref": "#/components/schemas/PublicBookableSpace"}},
        "payments": {"type": "array", "items": {"$ref": "#/components/schemas/MemberPayment"}},
        "documents": "DocumentPage", "preferences": "PreferenceResponse", "admin_spaces": "BookableSpaceListResponse",
        "direct_members": "PaginatedDirectLoanMemberList", "grants": "DeviceGrantPage",
        "risk_challenge": "MFAChallengeResponse", "checkin": "EventCheckInResolveResponse",
    }

    def test_payloads_carry_the_values_the_0_9_2_client_could_not_decode(self):
        def load(name):
            return json.loads((test_staff_fixtures.ROOT / "Fixtures/Contract" / (name + ".json")).read_text(encoding="utf-8"))
        self.assertIn("judge", load("me")["event_grants"][0]["permissions"])
        self.assertEqual(load("bootstrap")["makerspace"]["request_access"], "contact")
        self.assertEqual(load("payments")[0]["subject_type"], "loan_rental")
        self.assertEqual(load("documents")["results"][0]["kind"], "bill")
        self.assertEqual(load("preferences")["cells"][0]["feature"], "presence")
        self.assertEqual(load("spaces")[0]["kind"], "machine")
        self.assertEqual(load("admin_spaces")["results"][0]["kind"], "machine")
        self.assertEqual(load("inventory")["results"][0]["availability"]["label"], "Lent at events only")
        self.assertIsNone(load("direct_members")["results"][0]["membership_id"])
        self.assertNotIn("event_status", load("checkin"))
        self.assertEqual(load("risk_challenge")["purpose"], "risk")
