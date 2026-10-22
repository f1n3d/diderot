import Foundation

/// Turns input like `wiki.example.com`, `https://wiki.example.com/login` or `localhost:3000` into scheme, host, port.
nonisolated enum ServerURLNormalizer {
    static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
            return nil
        }
        let scheme = components.scheme?.lowercased() ?? "https"
        guard scheme == "http" || scheme == "https" else { return nil }

        // Without an explicit scheme, assume local dev instances run without TLS.
        if !input.contains("://"), isLocalHost(host) {
            components.scheme = "http"
        } else {
            components.scheme = scheme
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    static func isLocalHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        // URLComponents.host keeps the brackets of IPv6 literals.
        if lowered == "localhost" || lowered.hasSuffix(".local") || lowered == "[::1]" { return true }
        // Only IPv4 literals count, so names like 10.example.com keep https.
        let parts = lowered.components(separatedBy: ".")
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return false }
        return octets[0] == 10 || octets[0] == 127 || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}
