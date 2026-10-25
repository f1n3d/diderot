import Foundation

/// Links to other services that Docmost 0.97 shows as cards and inline mentions: which service and what a link points
/// to, read from its address (own rules from the services' public URL formats). Used while the server has no preview
/// (`Endpoints.Integrations.unfurl`) and to recognize a pasted link.
public enum IntegrationLinks {
    public enum Provider: String, Sendable, Hashable, CaseIterable {
        case github, gitlab, jira, linear, figma
        case azureDevOps = "azure_devops"
        case slack

        public var name: String {
            switch self {
            case .github: "GitHub"
            case .gitlab: "GitLab"
            case .jira: "Jira"
            case .linear: "Linear"
            case .figma: "Figma"
            case .azureDevOps: "Azure DevOps"
            case .slack: "Slack"
            }
        }

        /// Hosts the service uses for everyone; a workspace adds its own (self-hosted GitLab, Jira) as `unfurlHosts`.
        fileprivate func serves(_ host: String) -> Bool {
            switch self {
            case .github: host == "github.com" || host == "www.github.com"
            case .gitlab: host == "gitlab.com" || host == "www.gitlab.com"
            case .jira: host.hasSuffix(".atlassian.net")
            case .linear: host == "linear.app"
            case .figma: host == "figma.com" || host == "www.figma.com"
            case .azureDevOps: host == "dev.azure.com" || host.hasSuffix(".visualstudio.com")
            case .slack: host == "slack.com" || host.hasSuffix(".slack.com")
            }
        }
    }

    /// What a link points to.
    public enum Kind: String, Sendable, Hashable {
        case repository, issue, pullRequest, mergeRequest, commit, file, folder, discussion, release
        case project, initiative, view, design, prototype, board, slides, workItem, message
        /// An address of the service that is none of the above.
        case page
    }

    public struct Description: Sendable, Hashable {
        public let provider: Provider?
        public let kind: Kind
        /// Short name of the thing: `owner/repo#12`, `ABC-123`, a design's name; else host and path.
        public let title: String

        /// The text an inline mention shows while editing.
        public var inline: String { title }
    }

    /// The service and kind of a link, as far as its address tells; a link to an unknown service gets host and path.
    /// `unfurlHosts` are the workspace's own hosts per service (`Integration.unfurlHosts`, `*.example.com` for any
    /// subdomain).
    public static func describe(_ address: String, unfurlHosts: [String: [String]] = [:]) -> Description {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased()
        else {
            return Description(provider: nil, kind: .page, title: address)
        }
        let parts = url.pathComponents.filter { $0 != "/" }.map { $0.removingPercentEncoding ?? $0 }
        let provider = Provider.allCases.first { $0.serves(host) }
            ?? Provider.allCases.first { provider in (unfurlHosts[provider.rawValue] ?? []).contains { matches(host, $0) } }
        let fallback = Description(provider: provider, kind: .page, title: ([host] + parts).joined(separator: "/"))
        guard let provider else { return fallback }
        return described(provider, host: host, parts: parts, query: url.query()) ?? fallback
    }

    /// The service of a link the workspace can preview: a known kind of address of a service in `installed` (the
    /// types of its installed integrations). Nil for other links, so pasting them stays plain.
    public static func provider(of address: String, installed: Set<String>, unfurlHosts: [String: [String]] = [:]) -> Provider? {
        let description = describe(address, unfurlHosts: unfurlHosts)
        guard let provider = description.provider, description.kind != .page, installed.contains(provider.rawValue) else { return nil }
        return provider
    }

    // MARK: - Per service

    private static func described(_ provider: Provider, host: String, parts: [String], query: String?) -> Description? {
        func make(_ kind: Kind, _ title: String) -> Description { Description(provider: provider, kind: kind, title: title) }
        switch provider {
        case .github:
            guard parts.count >= 2 else { return nil }
            let repo = "\(parts[0])/\(parts[1])"
            guard parts.count >= 3 else { return make(.repository, repo) }
            let rest = Array(parts.dropFirst(2))
            switch rest[0] {
            case "issues" where rest.count >= 2 && isNumber(rest[1]): return make(.issue, "\(repo)#\(rest[1])")
            case "pull" where rest.count >= 2 && isNumber(rest[1]): return make(.pullRequest, "\(repo)#\(rest[1])")
            case "discussions" where rest.count >= 2 && isNumber(rest[1]): return make(.discussion, "\(repo)#\(rest[1])")
            case "commit" where rest.count >= 2: return make(.commit, "\(repo)@\(rest[1].prefix(7))")
            case "blob" where rest.count >= 3: return make(.file, rest.last ?? repo)
            case "tree" where rest.count >= 3: return make(.folder, rest.last ?? repo)
            case "releases" where rest.count >= 3 && rest[1] == "tag": return make(.release, "\(repo) \(rest[2])")
            default: return make(.repository, repo)
            }

        case .gitlab:
            // Groups nest: everything before "-" is the project's path.
            guard let dash = parts.firstIndex(of: "-") else {
                return parts.count >= 2 ? make(.project, parts.joined(separator: "/")) : nil
            }
            let project = parts[..<dash].joined(separator: "/")
            let rest = Array(parts[(dash + 1)...])
            guard !project.isEmpty, let first = rest.first else { return nil }
            switch first {
            case "issues" where rest.count >= 2 && isNumber(rest[1]): return make(.issue, "\(project)#\(rest[1])")
            case "merge_requests" where rest.count >= 2 && isNumber(rest[1]): return make(.mergeRequest, "\(project)!\(rest[1])")
            case "commit" where rest.count >= 2: return make(.commit, "\(project)@\(rest[1].prefix(7))")
            case "blob" where rest.count >= 3: return make(.file, rest.last ?? project)
            case "tree" where rest.count >= 3: return make(.folder, rest.last ?? project)
            default: return make(.project, project)
            }

        case .jira:
            if let key = parts.last(where: isIssueKey) ?? queryValue("selectedIssue", in: query).flatMap({ isIssueKey($0) ? $0 : nil }) {
                return make(.issue, key)
            }
            return nil

        case .linear:
            guard parts.count >= 3 else { return nil }
            switch parts[1] {
            case "issue" where isIssueKey(parts[2]): return make(.issue, parts[2])
            case "project": return make(.project, humanized(withoutTrailingId(parts[2])))
            case "initiative": return make(.initiative, humanized(withoutTrailingId(parts[2])))
            case "view": return make(.view, humanized(withoutTrailingId(parts[2])))
            default: return nil
            }

        case .figma:
            guard parts.count >= 2 else { return nil }
            let kind: Kind
            switch parts[0] {
            case "file", "design": kind = .design
            case "proto": kind = .prototype
            case "board": kind = .board
            case "slides": kind = .slides
            default: return nil
            }
            return make(kind, parts.count >= 3 ? humanized(parts[2]) : provider.name)

        case .azureDevOps:
            // dev.azure.com/{organization}/{project}/…, or {organization}.visualstudio.com/{project}/…
            let rest = host == "dev.azure.com" ? Array(parts.dropFirst()) : parts
            guard rest.count >= 2 else { return nil }
            if let edit = rest.firstIndex(of: "edit"), rest.dropLast().contains("_workitems"), edit + 1 < rest.count, isNumber(rest[edit + 1]) {
                return make(.workItem, "#\(rest[edit + 1])")
            }
            if let git = rest.firstIndex(of: "_git"), git + 3 < rest.count, rest[git + 2] == "pullrequest", isNumber(rest[git + 3]) {
                return make(.pullRequest, "\(rest[git + 1])!\(rest[git + 3])")
            }
            return nil

        case .slack:
            guard parts.count >= 3, parts[0] == "archives", parts[2].hasPrefix("p") else { return nil }
            return make(.message, provider.name)
        }
    }

    private static func matches(_ host: String, _ pattern: String) -> Bool {
        let pattern = pattern.lowercased()
        if pattern.hasPrefix("*.") { return host.hasSuffix(String(pattern.dropFirst(1))) }
        return host == pattern
    }

    private static func isNumber(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) }

    /// `ABC-123`: letters and digits starting with a letter, a dash, a number.
    private static func isIssueKey(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts[0].first, first.isLetter, first.isASCII, isNumber(String(parts[1])) else { return false }
        return parts[0].allSatisfy { ($0.isLetter || $0.isNumber || $0 == "_") && $0.isASCII }
    }

    private static func queryValue(_ name: String, in query: String?) -> String? {
        URLComponents(string: "?" + (query ?? ""))?.queryItems?.first { $0.name == name }?.value
    }

    /// `launch-plan-3f9a2c1b` → `launch-plan`: Linear ends a slug with an id.
    private static func withoutTrailingId(_ slug: String) -> String {
        guard let dash = slug.lastIndex(of: "-") else { return slug }
        let tail = slug[slug.index(after: dash)...]
        return tail.count >= 6 && tail.allSatisfy(\.isHexDigit) ? String(slug[..<dash]) : slug
    }

    /// `My-new-design` → `My new design`.
    private static func humanized(_ slug: String) -> String {
        let text = slug.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? slug : text
    }
}
