import Foundation
import Observation
import SpaceWorksAPI

protocol MemberActionsRepository: Sendable {
    func bootstrap() async throws -> Components.Schemas.TenantBootstrap
    func submit(items: [Components.Schemas.RequestItemInput], purpose: String, key: String) async throws -> Components.Schemas.RequestSubmitResponse
    func renew(request: Int) async throws -> Components.Schemas.LoanRenewal
    func availability(space: String, start: Date, end: Date) async throws -> Components.Schemas.PublicSpaceAvailability
    func book(space: String, input: Components.Schemas.PublicBookingInput) async throws -> MemberBookingCreated
    func cancelBooking(token: String) async throws -> Components.Schemas.MemberBooking
    func register(event: String, input: Components.Schemas.PublicEventRegistrationInput) async throws -> Components.Schemas.PublicEventRegistrationResponse
    func cancelEvent(registration: Int) async throws -> Components.Schemas.MemberRegistrationCancelResponse
    func eventQR(registration: Int) async throws -> Data
    func profile() async throws -> Components.Schemas.AccountProfile
    func updateProfile(_ input: Components.Schemas.PatchedAccountProfile) async throws -> Components.Schemas.AccountProfile
    func preferences() async throws -> Components.Schemas.PreferenceResponse
    func updatePreference(_ input: Components.Schemas.PatchedPreferenceWrite) async throws -> Components.Schemas.PreferenceResponse
    func reschedule(booking token: String, start: Date, end: Date) async throws -> Components.Schemas.MemberBooking
    func requestStatus(token: String) async throws -> Components.Schemas.PublicRequestStatus
}
extension MemberActionsRepository {
    func reschedule(booking token: String, start: Date, end: Date) async throws -> Components.Schemas.MemberBooking { throw APIError(status: 0, code: "unsupported", detail: String(localized: "This isn't available here.")) }
    func requestStatus(token: String) async throws -> Components.Schemas.PublicRequestStatus { throw APIError(status: 0, code: "unsupported", detail: String(localized: "This isn't available here.")) }
}

/// Review state is local UI data; submission/approval/status always come from generated results.
@MainActor @Observable
final class RequestCartState {
    struct Line: Identifiable {
        let product: Components.Schemas.PublicProduct
        var quantity: Int
        var id: Int { product.id }
    }
    private(set) var lines: [Line] = []
    var purpose = "" { didSet { if purpose != oldValue { changed() } } }
    private(set) var receipt: Components.Schemas.RequestSubmitResponse?
    /// The latest server status for the submitted request, read by its public token.
    private(set) var receiptStatus: String?
    private(set) var busy = false
    private(set) var error: String?
    private(set) var retryAfter: Date?
    private(set) var attemptKey = UUID().uuidString
    private(set) var feedback: NativeFeedbackEvent?
    private var generation = 0
    private var active = true
    let repository: any MemberActionsRepository
    init(repository: any MemberActionsRepository) { self.repository = repository }
    func add(_ product: Components.Schemas.PublicProduct) {
        guard !busy, active else { return }
        if let index = lines.firstIndex(where: { $0.id == product.id }) {
            guard lines[index].quantity < 99 else { error = String(localized: "Choose up to 99 of each item."); return }
            lines[index].quantity += 1
        } else {
            guard lines.count < 20 else { error = String(localized: "Request up to 20 different items at once."); return }
            lines.append(Line(product: product, quantity: 1))
        }
        changed()
    }
    func quantity(_ value: Int, for id: Int) {
        guard !busy, active, let index = lines.firstIndex(where: { $0.id == id }), (0...99).contains(value) else { return }
        if value == 0 { lines.remove(at: index) } else { lines[index].quantity = value }
        changed()
    }
    func submit(now: Date = Date()) async {
        guard active, !busy, (retryAfter ?? .distantPast) <= now else { return }
        guard !lines.isEmpty else { error = String(localized: "Add an item before submitting your request."); return }
        guard purpose.count <= 500 else { error = String(localized: "Keep the purpose to 500 characters or fewer."); return }
        busy = true; error = nil; receipt = nil
        let expected = generation
        let items = lines.map { Components.Schemas.RequestItemInput(product_id: $0.id, quantity: $0.quantity) }
        defer { busy = false }
        do {
            let result = try await repository.submit(items: items, purpose: purpose.trimmingCharacters(in: .whitespacesAndNewlines), key: attemptKey)
            guard active, generation == expected else { return }
            lines = []; purpose = ""; receipt = result
            attemptKey = UUID().uuidString; retryAfter = nil; feedback = .init(.success)
        } catch {
            guard active, generation == expected else { return }
            self.error = APIError.display(error); retryAfter = APIError.retryDeadline(error)
            if !APIError.isCancellation(error) { feedback = .init(.error) }
        }
    }
    /// Re-read the submitted request's status (`GET /public/requests/{public_token}/status`).
    func refreshReceiptStatus() async {
        guard active, !busy, let token = receipt?.public_token else { return }
        busy = true; error = nil
        defer { busy = false }
        let expected = generation
        do {
            let status = try await repository.requestStatus(token: token)
            guard active, generation == expected, receipt?.public_token == token else { return }
            receiptStatus = status.status
        } catch {
            guard active, generation == expected else { return }
            self.error = APIError.display(error); retryAfter = APIError.retryDeadline(error)
        }
    }
    func invalidate() { feedback = nil; active = false; generation += 1; lines = []; purpose = ""; receipt = nil; receiptStatus = nil; error = nil; retryAfter = nil }
    private func changed() { generation += 1; attemptKey = UUID().uuidString; receipt = nil; receiptStatus = nil; error = nil }
}

/// Change a booking's time. The server checks rules, availability and price before it moves.
@MainActor @Observable
final class BookingRescheduleState {
    var start: Date
    var end: Date
    private(set) var busy = false
    private(set) var error: String?
    private(set) var updated: Components.Schemas.MemberBooking?
    private let token: String
    private let repository: any MemberActionsRepository
    init(booking: Components.Schemas.MemberBooking, repository: any MemberActionsRepository) {
        token = booking.public_token; start = booking.starts_at; end = booking.ends_at; self.repository = repository
    }
    var valid: Bool { end > start }
    func reschedule() async -> Bool {
        guard !busy else { return false }
        guard valid else { error = String(localized: "Choose an end time after the start time."); return false }
        busy = true; error = nil
        defer { busy = false }
        do { updated = try await repository.reschedule(booking: token, start: start, end: end); return true }
        catch { if !APIError.isCancellation(error) { self.error = APIError.display(error) }; return false }
    }
}
