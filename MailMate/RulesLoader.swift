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

    static func load() -> String {
        if !FileManager.default.fileExists(atPath: rulesFileURL.path) {
            try? defaultRules.write(to: rulesFileURL,
                                    atomically: true,
                                    encoding: .utf8)
            return defaultRules
        }
        return (try? String(contentsOf: rulesFileURL, encoding: .utf8)) ?? defaultRules
    }

    static func openInEditor() {
        if !FileManager.default.fileExists(atPath: rulesFileURL.path) {
            _ = load()
        }
        NSWorkspace.shared.open(rulesFileURL)
    }
}
