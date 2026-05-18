import Foundation

/// Resolved per-session scope — apps/sites the sweep should keep open.
/// Built from the Intention's saved context + voice-intent additions.
/// The global Always-Allowed list is consulted SEPARATELY, not merged here,
/// so it can't be accidentally lost.
struct ResolvedScope: Equatable {
    var domains: Set<String>
    var bundleIds: Set<String>
    var voiceIntent: String

    /// Tokens extracted from the voice intent (project domains, stems, named
    /// tools). A tab whose host / URL / title contains any of these gets
    /// auto-kept — bypasses the AI batch. Pure string match, no model call.
    /// This is the "domain context" fix for the 8B+prompt benchmark plateau:
    /// the model couldn't connect "thebeseen.app" in intent with "Resend –
    /// thebeseen.app · Domains" in the tab title, so we do it ourselves.
    var intentKeywords: Set<String> = []

    static let empty = ResolvedScope(domains: [], bundleIds: [], voiceIntent: "")

    /// Suffix match — "github.com" matches "gist.github.com".
    func containsDomain(_ host: String) -> Bool {
        let h = host.lowercased()
        for d in domains {
            if h == d || h.hasSuffix("." + d) { return true }
        }
        return false
    }

    /// Substring match across host + path + title (all lowercased). Used for
    /// intent-keyword auto-keep: if the user mentioned `thebeseen.app` in
    /// intent, any tab with "thebeseen" anywhere in its host/URL/title is
    /// on-task without consulting the model.
    func matchesIntentKeyword(host: String, url: String, title: String) -> Bool {
        if intentKeywords.isEmpty { return false }
        let haystack = "\(host) \(url) \(title)".lowercased()
        for kw in intentKeywords where haystack.contains(kw) {
            return true
        }
        return false
    }
}

/// Extracts auto-keep tokens from the intent string. Pulls:
///   1. Domain-shaped tokens (word.tld, word.word.tld)
///   2. The "stem" of each domain (the label before the public TLD)
///   3. A small allowlist of common tool / IDE names if the intent
///      mentions them as bare words.
/// Returns a lowercase set, ready for matchesIntentKeyword.
enum IntentKeywordExtractor {

    /// Common tool / IDE / service names that may appear in an intent as bare
    /// words ("working in claude and cursor with the terminal"). When we see
    /// them in the intent, any tab whose title contains the same word becomes
    /// auto-keep — e.g. "Claude Code article" matches when intent says "claude".
    private static let toolAllowlist: [String] = [
        "claude", "cursor", "vscode", "xcode", "terminal", "iterm",
        "github", "gitlab", "bitbucket",
        "figma", "notion", "linear", "jira",
        "supabase", "firebase", "vercel", "netlify", "cloudflare",
        "railway", "render", "fly.io", "heroku", "aws",
        "stripe", "resend", "postmark", "sendgrid", "mailgun",
        "openai", "anthropic", "perplexity", "huggingface",
        "stackoverflow", "mdn",
    ]

    /// Public-suffix shortlist for stripping TLDs. Not exhaustive (no PSL
    /// dependency); just covers the common cases the user is likely to type.
    private static let knownTLDs: [String] = [
        "com", "org", "net", "io", "ai", "app", "co", "dev", "sh",
        "xyz", "tech", "to", "me", "info", "biz", "us", "uk", "ca",
        "edu", "gov", "fyi", "studio", "page", "site", "cloud",
    ]

    static func extract(from intent: String) -> Set<String> {
        var out = Set<String>()
        let lower = intent.lowercased()

        // 1. Domain-shaped tokens via regex: word(.word)+.tld
        //    Matches "thebeseen.app", "dash.cloudflare.com", "api.openai.com".
        let domainPattern = #"\b([a-z0-9][a-z0-9\-]*(?:\.[a-z0-9][a-z0-9\-]*)+)\b"#
        if let re = try? NSRegularExpression(pattern: domainPattern, options: []) {
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            re.enumerateMatches(in: lower, options: [], range: range) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2,
                      let r = Range(m.range(at: 1), in: lower) else { return }
                let candidate = String(lower[r])
                let parts = candidate.split(separator: ".")
                guard parts.count >= 2 else { return }
                let tld = String(parts.last!)
                // Only treat as a domain if the suffix matches a known TLD —
                // avoids false-positives like "v1.2" or "foo.bar" being mined.
                if knownTLDs.contains(tld) {
                    out.insert(candidate)
                    // Stem (label before TLD) so "thebeseen.app" also matches
                    // tabs whose title contains the bare "thebeseen".
                    let stem = String(parts[parts.count - 2])
                    if stem.count >= 4 { out.insert(stem) }
                }
            }
        }

        // 2. Tool allowlist — bare-word match against the intent.
        //    "claude" in intent → any tab title containing "claude" auto-keeps.
        for tool in toolAllowlist where lower.contains(tool) {
            out.insert(tool)
        }

        return out
    }
}

enum TabVerdict: Equatable {
    case keep       // explicit allow OR pinned OR in scope
    case stash      // explicit deny (block rule) OR AI verdict false
    case needsAI    // not classified — caller must batch-score
}

enum AppVerdict: Equatable {
    case keep
    case hide
}

/// Stateless decision logic. Async sweep orchestration lives in
/// AppDelegate / a small Sweeper.run(...) coroutine, not here, so the
/// pure logic stays trivially testable.
enum Sweeper {

    /// Three-tier per-tab decision. `blockedHosts` should contain only
    /// hosts from BlockRules that are CURRENTLY ENFORCING (toggle on,
    /// inside their scheduled window).
    static func decideTab(host: String,
                          isPinned: Bool,
                          blockedHosts: Set<String>,
                          scope: ResolvedScope,
                          alwaysAllowed: AlwaysAllowedList) -> TabVerdict {
        if isPinned { return .keep }
        let h = host.lowercased()
        // Always-allowed (global) takes precedence over everything.
        for d in alwaysAllowed.domains {
            if h == d || h.hasSuffix("." + d) { return .keep }
        }
        // Active block rule — overrides AI.
        for d in blockedHosts {
            if h == d || h.hasSuffix("." + d) { return .stash }
        }
        // In-scope (voice/Intention-derived).
        if scope.containsDomain(h) { return .keep }
        return .needsAI
    }

    /// Native app decision. No AI involvement for apps in v1 — the user-named
    /// list (scope.bundleIds) plus always-allowed plus block rules is enough.
    /// Anything outside those three buckets gets hidden by default.
    static func decideApp(bundleId: String,
                          blockedBundleIds: Set<String>,
                          scope: ResolvedScope,
                          alwaysAllowed: AlwaysAllowedList) -> AppVerdict {
        if alwaysAllowed.bundleIds.contains(bundleId) { return .keep }
        if blockedBundleIds.contains(bundleId) { return .hide }
        if scope.bundleIds.contains(bundleId) { return .keep }
        return .hide
    }
}
