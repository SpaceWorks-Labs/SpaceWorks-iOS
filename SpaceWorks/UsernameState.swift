import Foundation
import Observation
import SpaceWorksAPI

/// "Choose your username": the blocking step for accounts the server marks `handle_required`
/// (state-changing member routes answer 403 `handle_required` until one is chosen). The server
/// owns the rules; the app shows its availability answer and suggestion and never guesses.
@MainActor @Observable
final class UsernameState: Identifiable {
    let id = UUID()
    var handle: String { didSet { if handle != oldValue { availability = nil; checkedHandle = nil } } }
    private(set) var suggestion: String?
    /// The server's answer for `checkedHandle`: true/false, or nil when it could not say.
    private(set) var availability: Bool?
    private(set) var reason: String?
    private(set) var checkedHandle: String?
    private(set) var busy = false
    private(set) var error: String?
    private let check: @Sendable (String) async throws -> Components.Schemas.HandleCheckResponse
    private let claim: @Sendable (String) async throws -> Void

    init(suggestion: String?, check: @escaping @Sendable (String) async throws -> Components.Schemas.HandleCheckResponse,
         claim: @escaping @Sendable (String) async throws -> Void) {
        self.suggestion = suggestion; self.handle = suggestion ?? ""
        self.check = check; self.claim = claim
    }

    var trimmed: String { handle.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canSubmit: Bool { !busy && !trimmed.isEmpty && trimmed.count <= 30 && availability != false }

    /// Live availability check. A stale answer for an edited field is discarded.
    func checkAvailability() async {
        let value = trimmed
        guard !value.isEmpty, value.count <= 30 else { availability = nil; return }
        do {
            let result = try await check(value)
            guard value == trimmed else { return }
            checkedHandle = value
            availability = result.available
            reason = result.reason.isEmpty ? nil : result.reason
            if let next = result.suggestion, !next.isEmpty { suggestion = next }
            error = nil
        } catch {
            guard !APIError.isCancellation(error), value == trimmed else { return }
            availability = nil
            self.error = APIError.display(error)
        }
    }

    func useSuggestion() { if let suggestion { handle = suggestion } }

    func submit() async {
        let value = trimmed
        guard !busy else { return }
        guard !value.isEmpty, value.count <= 30 else { error = String(localized: "Enter a username of up to 30 characters."); return }
        busy = true; error = nil
        defer { busy = false }
        do { try await claim(value) }
        catch { if !APIError.isCancellation(error) { self.error = APIError.display(error) } }
    }

    /// Plain-language copy for the server's `reason` codes; an unknown code still reads sensibly.
    var unavailableMessage: String {
        switch reason {
        case "taken": return String(localized: "That username is taken.")
        case "reserved": return String(localized: "That username is reserved.")
        case "invalid": return String(localized: "That username can't be used. Try letters and numbers.")
        default: return String(localized: "That username isn't available.")
        }
    }
}
