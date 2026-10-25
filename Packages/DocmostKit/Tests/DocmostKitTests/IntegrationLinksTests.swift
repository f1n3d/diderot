import Testing
@testable import DocmostKit

/// What links to other services point to, read from their addresses (cards and mentions without a server preview).
struct IntegrationLinksTests {
    private func describe(_ url: String, hosts: [String: [String]] = [:]) -> (provider: IntegrationLinks.Provider?, kind: IntegrationLinks.Kind, title: String) {
        let description = IntegrationLinks.describe(url, unfurlHosts: hosts)
        return (description.provider, description.kind, description.title)
    }

    @Test func github() {
        #expect(describe("https://github.com/docmost/docmost") == (.github, .repository, "docmost/docmost"))
        #expect(describe("https://github.com/docmost/docmost/issues/12") == (.github, .issue, "docmost/docmost#12"))
        #expect(describe("https://github.com/docmost/docmost/pull/2606/files") == (.github, .pullRequest, "docmost/docmost#2606"))
        #expect(describe("https://github.com/docmost/docmost/commit/e113d652abcdef") == (.github, .commit, "docmost/docmost@e113d65"))
        #expect(describe("https://github.com/o/r/blob/main/apps/server/main.ts") == (.github, .file, "main.ts"))
        #expect(describe("https://github.com/o/r/tree/main/apps") == (.github, .folder, "apps"))
        #expect(describe("https://github.com/o/r/discussions/7") == (.github, .discussion, "o/r#7"))
        #expect(describe("https://github.com/o/r/releases/tag/v1.0.0") == (.github, .release, "o/r v1.0.0"))
        #expect(describe("https://github.com/o/r/issues") == (.github, .repository, "o/r"))
        #expect(describe("https://github.com/someone") == (.github, .page, "github.com/someone"))
    }

    @Test func gitlab() {
        #expect(describe("https://gitlab.com/group/sub/project/-/issues/3") == (.gitlab, .issue, "group/sub/project#3"))
        #expect(describe("https://gitlab.com/g/p/-/merge_requests/9") == (.gitlab, .mergeRequest, "g/p!9"))
        #expect(describe("https://gitlab.com/g/p/-/commit/0123456789") == (.gitlab, .commit, "g/p@0123456"))
        #expect(describe("https://gitlab.com/g/p") == (.gitlab, .project, "g/p"))
        // A workspace's own GitLab, from the integration's unfurl hosts.
        #expect(describe("https://git.example.org/g/p/-/issues/1", hosts: ["gitlab": ["git.example.org"]]) == (.gitlab, .issue, "g/p#1"))
        #expect(describe("https://code.dev.example.org/g/p/-/issues/1", hosts: ["gitlab": ["*.example.org"]]) == (.gitlab, .issue, "g/p#1"))
        #expect(describe("https://git.example.org/g/p/-/issues/1").provider == nil)
    }

    @Test func jiraLinearFigma() {
        #expect(describe("https://acme.atlassian.net/browse/ABC-123") == (.jira, .issue, "ABC-123"))
        #expect(describe("https://acme.atlassian.net/jira/software/projects/ABC/boards/1?selectedIssue=ABC-7") == (.jira, .issue, "ABC-7"))
        #expect(describe("https://linear.app/acme/issue/ENG-42/fix-the-crash") == (.linear, .issue, "ENG-42"))
        #expect(describe("https://linear.app/acme/project/launch-plan-3f9a2c1b0d4e") == (.linear, .project, "launch plan"))
        #expect(describe("https://www.figma.com/design/AbCdEf123/My-New-Design?node-id=1-2") == (.figma, .design, "My New Design"))
        #expect(describe("https://www.figma.com/board/AbC/Retro") == (.figma, .board, "Retro"))
        #expect(describe("https://www.figma.com/proto/AbC") == (.figma, .prototype, "Figma"))
    }

    @Test func azureDevOpsAndSlack() {
        #expect(describe("https://dev.azure.com/org/project/_workitems/edit/345") == (.azureDevOps, .workItem, "#345"))
        #expect(describe("https://org.visualstudio.com/project/_workitems/edit/12") == (.azureDevOps, .workItem, "#12"))
        #expect(describe("https://dev.azure.com/org/project/_git/web/pullrequest/77") == (.azureDevOps, .pullRequest, "web!77"))
        #expect(describe("https://acme.slack.com/archives/C024BE91L/p1700000000123456") == (.slack, .message, "Slack"))
    }

    @Test func otherLinks() {
        #expect(describe("https://example.com/a/b") == (nil, .page, "example.com/a/b"))
        #expect(describe("mailto:someone@example.com").provider == nil)
        #expect(describe("not a link") == (nil, .page, "not a link"))
    }

    /// Pasting offers a card or mention only for kinds the workspace's installed integrations preview.
    @Test func pastedLinks() {
        let issue = "https://github.com/o/r/issues/1"
        #expect(IntegrationLinks.provider(of: issue, installed: ["github"]) == .github)
        #expect(IntegrationLinks.provider(of: issue, installed: ["linear"]) == nil)
        #expect(IntegrationLinks.provider(of: "https://github.com/someone", installed: ["github"]) == nil)
        #expect(IntegrationLinks.provider(of: "https://example.com", installed: ["github"]) == nil)
    }
}
