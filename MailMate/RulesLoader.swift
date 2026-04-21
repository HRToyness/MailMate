import AppKit

enum RulesLoader {
    static var rulesFileURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let appDir = appSupport.appendingPathComponent("MailMate", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir,
                                                 withIntermediateDirectories: true)
        return appDir.appendingPathComponent("rules.md")
    }

    static var overridesFileURL: URL {
        rulesFileURL.deletingLastPathComponent().appendingPathComponent("rules-overrides.md")
    }

    static let defaultRules = """
    # MailMate Rules

    ## Who I am
    - I'm Teun, founder of Toyness IT (Dutch software consultancy).
    - Clients span horticulture, construction, education, and service sectors.

    ## Tone
    - Professional but not stiff. Direct. No corporate filler.
    - Dutch clients: gebruik "je" tenzij de afzender duidelijk formeel is.
    - English clients: friendly and concise.

    ## Never
    - Commit to specific delivery dates without [CONFIRM].
    - Quote prices or estimates without [CONFIRM].
    - Schedule meetings without [CONFIRM — check calendar].

    ## Prefer
    - Short paragraphs. One topic per paragraph.
    - If the email asks multiple questions, answer in the same order.
    - If the email is a quote request, acknowledge and say I'll follow up with a detailed proposal.

    ## Signature
    Do not write a signature. Mail.app appends mine automatically.
    """

    /// Seed content for the overrides file shown when the user opens it for
    /// the first time. The format is `## <pattern>` sections with rule text
    /// underneath. Pattern forms:
    /// - `domain.com` — match addresses ending in @domain.com (or any subdomain).
    /// - `*.domain.com` — match any subdomain of domain.com.
    /// - `alice@example.com` — match a specific address.
    static let defaultOverrides = """
    # MailMate Overrides
    # Per-sender rule overrides. Each "## <pattern>" section REPLACES the
    # base rules in rules.md when the sender matches. First match wins.
    #
    # Pattern examples:
    #   ## example.com            → any @example.com or subdomain
    #   ## *.school.nl            → any subdomain of school.nl
    #   ## alice@example.com      → exact address
    #
    # Delete this file to disable overrides entirely.

    ## example-horti-client.nl
    - Sector: horticulture. Assume the reader knows industry terms (CO2, EC,
      substraat, teelt).
    - Formal "u" form in Dutch.
    - Always mention we follow up with a formal proposal in writing before
      any commercial agreement.

    ## *.school.nl
    - Sector: education. Assume limited IT budget and long decision cycles.
    - Never quote prices inline; offer to schedule a budget conversation
      separately.
    - Tone: warm and patient.
    """

    static func load() -> String {
        if !FileManager.default.fileExists(atPath: rulesFileURL.path) {
            try? defaultRules.write(to: rulesFileURL,
                                    atomically: true,
                                    encoding: .utf8)
            return defaultRules
        }
        return (try? String(contentsOf: rulesFileURL, encoding: .utf8)) ?? defaultRules
    }

    /// Returns the rules text to use for a given sender line from a Mail
    /// message ("Name <alice@example.com>" or just an address). If an
    /// overrides file exists and a pattern matches, that section replaces
    /// the base rules. Otherwise returns `load()`.
    static func rules(for senderLine: String) -> String {
        let base = load()
        guard let address = extractAddress(from: senderLine) else { return base }
        guard let overrides = loadOverrides(), !overrides.isEmpty else { return base }
        if let matched = firstMatchingSection(in: overrides, address: address) {
            Log.write("Rules override hit: pattern='\(matched.pattern)' sender='\(address)'")
            return matched.rules
        }
        return base
    }

    static func loadOverrides() -> String? {
        guard FileManager.default.fileExists(atPath: overridesFileURL.path) else { return nil }
        return try? String(contentsOf: overridesFileURL, encoding: .utf8)
    }

    /// Extracts just the email address from a sender line like
    /// "Alice <alice@example.com>" or "alice@example.com".
    static func extractAddress(from line: String) -> String? {
        // Prefer text between angle brackets.
        if let start = line.firstIndex(of: "<"),
           let end = line.firstIndex(of: ">"),
           start < end {
            let inside = line[line.index(after: start)..<end]
            let trimmed = inside.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("@") { return trimmed.lowercased() }
        }
        // Otherwise find an @-containing token.
        let tokens = line.split(whereSeparator: { $0.isWhitespace })
        for token in tokens where token.contains("@") {
            return token.trimmingCharacters(in: CharacterSet(charactersIn: "<>,;\""))
                .lowercased()
        }
        return nil
    }

    struct Match { let pattern: String; let rules: String }

    static func firstMatchingSection(in overrides: String, address: String) -> Match? {
        // Parse "## <pattern>\n<body>" sections. Ignore comment lines.
        let lines = overrides.components(separatedBy: .newlines)
        var sections: [(pattern: String, lines: [String])] = []
        var current: (pattern: String, lines: [String])?

        for raw in lines {
            if raw.hasPrefix("## ") {
                if let c = current { sections.append(c) }
                let pattern = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !pattern.isEmpty {
                    current = (pattern.lowercased(), [])
                } else {
                    current = nil
                }
            } else {
                current?.lines.append(raw)
            }
        }
        if let c = current { sections.append(c) }

        // Skip preamble and comment-only sections.
        for section in sections {
            if matches(pattern: section.pattern, address: address) {
                let body = section.lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Match(pattern: section.pattern, rules: body)
            }
        }
        return nil
    }

    private static func matches(pattern: String, address: String) -> Bool {
        // Exact address match.
        if pattern.contains("@") {
            return pattern == address
        }
        let domain = address.split(separator: "@").last.map(String.init) ?? ""
        if domain.isEmpty { return false }

        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return domain == suffix || domain.hasSuffix("." + suffix)
        }
        // Bare domain: match the domain exactly or any subdomain.
        return domain == pattern || domain.hasSuffix("." + pattern)
    }

    /// Opens the built-in rules editor window for the base rules. Callers
    /// pass `overrides: true` to open the overrides file instead.
    static func openInEditor(overrides: Bool = false) {
        let url = overrides ? overridesFileURL : rulesFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            if overrides {
                try? defaultOverrides.write(to: url, atomically: true, encoding: .utf8)
            } else {
                _ = load()
            }
        }
        MainActor.assumeIsolated {
            RulesEditor.shared.show(editing: overrides ? .overrides : .base)
        }
    }
}
