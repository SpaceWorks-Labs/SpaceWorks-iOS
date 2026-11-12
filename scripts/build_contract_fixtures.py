"""Build 0.12.0 contract payloads that carry the values added since the 0.9.2 pin.

Each payload is generated from the pinned schema (`build_staff_fixtures.model`, required fields
only) and then given a value that the 0.9.2 client could not decode: a new enum member, a null
that used to be required, an absent field that used to be required, or a new response shape.
`scripts/tests/test_contract_fixtures.py` validates them against the authoritative schema and the
Swift tests decode them through the generated client (`ContractDecodingTests`).
"""
import json
from build_staff_fixtures import ROOT, model

MEMBER = ROOT / "Fixtures/Member"


def member(name):
    return json.loads((MEMBER / (name + ".json")).read_text(encoding="utf-8"))


def build():
    makerspace = {"id": 7, "slug": "fab-lab-kochi", "name": "Fab Lab Kochi"}
    membership = model("AuthMembership", id=7, slug="fab-lab-kochi", name="Fab Lab Kochi", role="member", role_name="Member",
                       source="membership", actions=["submit_request"], tracks=["community"], status="active")
    me = model("AuthUserPayload", id=12, username="meera", display_name="Meera Nair", email="meera@example.test",
               email_verified=True, role="member", kind="person", session_authority="member", effective_locale="en",
               makerspaces=[membership], handle="meera", handle_required=False, has_staff_role=True,
               event_grants=[model("GrantedEventEntry", event_id=801, makerspace_id=7, title="Sample hackathon",
                                   permissions=["judge", "mentor_queue", "check_in"])])
    staff_me = dict(me, session_authority="native_staff", staff_roles=[{
        "makerspace": makerspace, "roles": [{"id": 3, "slug": "handover", "name": "Handover"}],
        "actions": ["issue_request", "return_request", "upload_evidence", "manage_bookings"]}])
    handle_required = dict(me, handle=None, handle_required=True, handle_suggestion="meera.nair")
    bootstrap = member("bootstrap")
    bootstrap["makerspace"]["request_access"] = "contact"
    spaces = member("spaces")
    spaces[0]["kind"] = "machine"
    inventory = member("inventory")
    inventory["results"][0]["availability"] = {"mode": "status_only", "label": "Lent at events only"}
    fixtures = {
        "me": me,
        "me_staff": staff_me,
        "me_handle_required": handle_required,
        "bootstrap": bootstrap,
        "spaces": spaces,
        "inventory": inventory,
        "payments": [model("MemberPayment", id=501, subject_type="loan_rental", subject_label="Rental: oscilloscope",
                           status="pending", amount="120.00", currency="INR", due_state="due", online_payment_available=True,
                           created_at="2026-11-01T09:00:00Z")],
        "documents": model("DocumentPage", count=1, results=[model("PaymentDocument", id=601, payment=501, number="BILL-0001",
                                                                   kind="bill", amount="120.00", currency="INR")]),
        "preferences": model("PreferenceResponse", cells=[model("PreferenceCell", feature="presence", channel="email",
                                                                enabled=True, available=True, mandatory_events=[])]),
        "admin_spaces": model("BookableSpaceListResponse", count=1, results=[model("BookableSpaceAdmin", id=901, makerspace_id=7,
                                                                                  name="Laser cutter time", kind="machine", is_active=True, capacity=1)]),
        "direct_members": model("PaginatedDirectLoanMemberList", count=1, results=[model("DirectLoanMember", user_id=52, membership_id=None,
                                                                                         display_name="Day pass guest", username="guest52",
                                                                                         is_guest_pass=True, pass_valid_until="2026-11-12T18:29:59.123456+00:00")]),
        "grants": model("DeviceGrantPage", count=2, next=None, results=[
            model("DeviceGrant", id="83000000-0000-4000-8000-000000000001", platform="apple", app_id="org.spaceworks.app",
                  environment="production", status="active", authority="member", login_method="password"),
            model("DeviceGrant", id="83000000-0000-4000-8000-000000000003", platform="apple", app_id="org.spaceworks.app",
                  environment="production", status="active", authority="staff", staff_makerspace_id=7, login_method="password")]),
        "risk_challenge": model("MFAChallengeResponse", mfa_required=True, enrollment_required=False,
                                challenge="risk-challenge-0000000000000001", expires_in=600, purpose="risk", factors=["email_code"]),
    }
    checkin = model("EventCheckInResolveResponse", registration_id=1101, name="Meera Nair", status="registered", confirmable=True)
    checkin.pop("event_status", None)
    checkin.pop("payment_status", None)
    fixtures["checkin"] = checkin
    directory = ROOT / "Fixtures/Contract"
    directory.mkdir(parents=True, exist_ok=True)
    for name, value in fixtures.items():
        (directory / (name + ".json")).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    build()
