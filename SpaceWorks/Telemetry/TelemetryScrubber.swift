import Foundation

/// Diagnostics scrubbing applied before any crash, error, breadcrumb or span leaves the device.
enum TelemetryScrubber {
    /// Headers never sent, compared case-insensitively.
    static let droppedHeaders: Set<String> = ["authorization", "cookie", "set-cookie", "x-makerspace-id", "proxy-authorization"]

    /// Keeps scheme, host, port and the path template: no credentials, query or fragment;
    /// numeric, UUID and opaque-token path segments become `{id}`.
    static func url(_ value: String) -> String {
        guard let components = URLComponents(string: value), let scheme = components.scheme, let host = components.host else { return path(value) }
        return scheme + "://" + host + (components.port.map { ":\($0)" } ?? "") + path(components.percentEncodedPath)
    }

    /// A bare path (or a span/transaction description such as `GET /api/v1/items/7?x=1`).
    static func path(_ value: String) -> String {
        let withoutQuery = value.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? value
        let withoutFragment = withoutQuery.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? withoutQuery
        return withoutFragment.split(separator: "/", omittingEmptySubsequences: false).map { segment -> String in
            identifier(String(segment)) ? "{id}" : String(segment)
        }.joined(separator: "/")
    }

    static func headers(_ headers: [String: String]) -> [String: String] {
        headers.filter { !droppedHeaders.contains($0.key.lowercased()) }
    }

    /// Breadcrumb/span data: URLs scrubbed, query/fragment/body keys and anything header-shaped removed.
    static func data(_ data: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in data {
            let lowered = key.lowercased()
            if ["http.query", "http.fragment", "request_body", "response_body", "body", "query", "headers"].contains(lowered)
                || droppedHeaders.contains(lowered) { continue }
            if let text = value as? String, lowered == "url" || lowered.hasSuffix(".url") || lowered == "description" { result[key] = url(text) }
            else { result[key] = value }
        }
        return result
    }

    private static func identifier(_ segment: String) -> Bool {
        guard !segment.isEmpty else { return false }
        if segment.allSatisfy(\.isNumber) { return true }
        if UUID(uuidString: segment) != nil { return true }
        // Opaque public tokens (booking/space/event tokens): long, mixed letters and digits.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return segment.count >= 16 && segment.unicodeScalars.allSatisfy(allowed.contains) && segment.contains(where: \.isNumber)
    }
}
