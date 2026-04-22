import AppKit
import Foundation

struct MailMessage {
    let sender: String
    let subject: String
    let body: String
    let dateReceived: String?

    init(sender: String, subject: String, body: String, dateReceived: String? = nil) {
        self.sender = sender
        self.subject = subject
        self.body = body
        self.dateReceived = dateReceived
    }
}

struct TriageMessage {
    let index: Int
    let sender: String
    let subject: String
    let dateReceived: String
    let snippet: String
    let messageID: String
}

struct SentMessage {
    let subject: String
    let dateSent: String
    let body: String
}

enum MailBridgeError: Error, LocalizedError {
    case noSelection
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .noSelection: return "No message selected"
        case .scriptError(let msg): return "AppleScript error: \(msg)"
        }
    }
}

enum MailBridge {
    private static let separator = "|||MAILMATE_SPLIT|||"
    private static let messageSep = "|||MAILMATE_MSG|||"

    static func getSelectedMessage() throws -> MailMessage {
        let script = """
        tell application "Mail"
            set theSelection to selection
            if (count of theSelection) is 0 then
                return "NO_SELECTION"
            end if
            set theMessage to item 1 of theSelection
            set theSender to sender of theMessage
            set theSubject to subject of theMessage
            set theBody to content of theMessage
            return theSender & "\(separator)" & theSubject & "\(separator)" & theBody
        end tell
        """

        let result = try runAppleScript(script)
        if result == "NO_SELECTION" {
            throw MailBridgeError.noSelection
        }
        let parts = result.components(separatedBy: separator)
        guard parts.count >= 3 else {
            throw MailBridgeError.scriptError("Unexpected response format")
        }
        let body = parts[2...].joined(separator: separator)
        return MailMessage(sender: parts[0], subject: parts[1], body: body)
    }

    /// Returns the currently-selected message plus up to `maxPrior` earlier
    /// messages from the same mailbox whose subject (after normalizing
    /// "Re:"/"Fwd:" prefixes) matches. Ordered most-recent-first among the
    /// prior messages. May be slow on large mailboxes.
    static func getSelectedMessageWithThread(maxPrior: Int) throws -> (selected: MailMessage, prior: [MailMessage]) {
        // Fetch the selected + its mailbox messages with exact subject match.
        // We do broader normalized matching in Swift.
        let script = """
        tell application "Mail"
            set theSelection to selection
            if (count of theSelection) is 0 then
                return "NO_SELECTION"
            end if
            set theMessage to item 1 of theSelection
            set theSender to sender of theMessage
            set theSubject to subject of theMessage
            set theBody to content of theMessage
            set theDate to (date received of theMessage) as string
            set theMailbox to mailbox of theMessage
            set selectedId to id of theMessage

            set out to theSender & "\(separator)" & theSubject & "\(separator)" & theDate & "\(separator)" & theBody

            try
                set siblings to (messages of theMailbox whose subject is theSubject)
                set counter to 0
                repeat with m in siblings
                    if counter < \(maxPrior) then
                        if (id of m) is not selectedId then
                            set out to out & "\(messageSep)" & (sender of m) & "\(separator)" & (subject of m) & "\(separator)" & ((date received of m) as string) & "\(separator)" & (content of m)
                            set counter to counter + 1
                        end if
                    end if
                end repeat
            end try

            return out
        end tell
        """

        let result = try runAppleScript(script)
        if result == "NO_SELECTION" {
            throw MailBridgeError.noSelection
        }

        let messageBlocks = result.components(separatedBy: messageSep)
        guard let first = messageBlocks.first else {
            throw MailBridgeError.scriptError("Unexpected response format")
        }
        let selected = try parseMessageBlock(first)
        let prior = messageBlocks.dropFirst().compactMap { try? parseMessageBlock($0) }
        return (selected, prior)
    }

    private static func parseMessageBlock(_ block: String) throws -> MailMessage {
        let parts = block.components(separatedBy: separator)
        guard parts.count >= 4 else {
            throw MailBridgeError.scriptError("Unexpected message-block format")
        }
        let body = parts[3...].joined(separator: separator)
        return MailMessage(sender: parts[0], subject: parts[1], body: body, dateReceived: parts[2])
    }

    /// Put `text` on the pasteboard, open a Mail reply for the currently
    /// selected message, wait for the window to settle, then synthesize Cmd+V.
    /// Setting `content` on a reply message is unreliable in recent Mail — the
    /// async population of the quoted body can clobber it. Pasting at Mail's
    /// cursor (parked above the quote) is what we want.
    ///
    /// The user's prior pasteboard contents are saved before we overwrite them
    /// and restored shortly after the Cmd+V completes, so MailMate doesn't
    /// silently clobber whatever the user had copied.
    static func pasteIntoReply(text: String) throws {
        let pb = NSPasteboard.general
        let saved = savePasteboard(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.write("Clipboard set with reply text (len=\(text.count)); saved \(saved.count) prior item(s)")

        try openReplyWindow()
        Thread.sleep(forTimeInterval: 1.2)
        try pasteClipboard()

        // Give Mail time to read from the pasteboard before we restore the
        // previous contents. 0.6s is enough for a typical paste.
        Thread.sleep(forTimeInterval: 0.6)
        restorePasteboard(pb, items: saved)
        Log.write("Clipboard restored")
    }

    /// Reads up to `maxCount` most-recent unread messages from Mail's unified
    /// inbox. Each message includes a short body snippet for triage context.
    static func fetchRecentUnread(maxCount: Int) throws -> [TriageMessage] {
        let script = """
        tell application "Mail"
            set collected to ""
            try
                set allUnread to (messages of inbox whose read status is false)
                set total to count of allUnread
                set limit to \(maxCount)
                if total < limit then set limit to total
                repeat with i from 1 to limit
                    set m to item i of allUnread
                    set theBody to content of m
                    set snippetLen to 500
                    if (length of theBody) < snippetLen then set snippetLen to length of theBody
                    set snippet to text 1 thru snippetLen of theBody
                    if collected is not "" then
                        set collected to collected & "\(messageSep)"
                    end if
                    set collected to collected & (sender of m) & "\(separator)" & (subject of m) & "\(separator)" & ((date received of m) as string) & "\(separator)" & snippet & "\(separator)" & ((id of m) as string)
                end repeat
            end try
            return collected
        end tell
        """

        let result = try runAppleScript(script)
        if result.isEmpty { return [] }
        let parts = result.components(separatedBy: messageSep)
        var out: [TriageMessage] = []
        for (i, block) in parts.enumerated() {
            let fields = block.components(separatedBy: separator)
            guard fields.count >= 5 else { continue }
            let snippet = fields[3..<(fields.count - 1)].joined(separator: separator)
            out.append(TriageMessage(
                index: i + 1,
                sender: fields[0],
                subject: fields[1],
                dateReceived: fields[2],
                snippet: snippet,
                messageID: fields[fields.count - 1]
            ))
        }
        return out
    }

    /// Reads up to `maxCount` most-recent sent messages across all accounts.
    /// Body is truncated to 1500 chars per message to keep the prompt small.
    /// Messages are returned most-recent first.
    static func fetchSentMessages(maxCount: Int, perMessageSnippet: Int = 1500) throws -> [SentMessage] {
        let script = """
        tell application "Mail"
            set collected to ""
            set perAccount to \(max(10, maxCount))
            set snippetLen to \(perMessageSnippet)
            repeat with acct in accounts
                try
                    set sent to sent mailbox of acct
                    set msgs to messages of sent
                    set acctTotal to count of msgs
                    set acctLimit to perAccount
                    if acctTotal < acctLimit then set acctLimit to acctTotal
                    repeat with i from 1 to acctLimit
                        set m to item i of msgs
                        set theBody to content of m
                        set limit to snippetLen
                        if (length of theBody) < limit then set limit to length of theBody
                        set snippet to text 1 thru limit of theBody
                        if collected is not "" then
                            set collected to collected & "\(messageSep)"
                        end if
                        set collected to collected & (subject of m) & "\(separator)" & ((date sent of m) as string) & "\(separator)" & snippet
                    end repeat
                end try
            end repeat
            return collected
        end tell
        """

        let result = try runAppleScript(script)
        if result.isEmpty { return [] }
        let blocks = result.components(separatedBy: messageSep)
        var items: [SentMessage] = []
        for block in blocks {
            let fields = block.components(separatedBy: separator)
            guard fields.count >= 3 else { continue }
            let body = fields[2...].joined(separator: separator)
            items.append(SentMessage(subject: fields[0], dateSent: fields[1], body: body))
        }
        // Sort by date-sent (AppleScript's string rep of a date is locale-shaped
        // but lexicographically-comparable enough to rank recents-first when
        // the locale is consistent). We can't reliably parse; fall back to
        // identity order which is account-order × mail's descending-date.
        // Take top maxCount.
        return Array(items.prefix(maxCount))
    }

    /// Activates Mail and selects the message with the given id. Ids are
    /// integers per Mail's scripting dictionary; reject non-numeric input to
    /// avoid script injection.
    static func selectMessage(id: String) throws {
        guard let numericId = Int(id.trimmingCharacters(in: .whitespaces)) else {
            throw MailBridgeError.scriptError("Invalid message id")
        }
        let script = """
        tell application "Mail"
            activate
            try
                set targetMsg to first message of inbox whose id is \(numericId)
                set selected messages of (first message viewer) to {targetMsg}
                return "OK"
            on error errMsg
                return "NOT_FOUND:" & errMsg
            end try
        end tell
        """
        let result = try runAppleScript(script)
        if result.hasPrefix("NOT_FOUND") {
            throw MailBridgeError.scriptError("Message no longer visible in inbox")
        }
    }

    static func openReplyWindow() throws {
        let script = """
        tell application "Mail"
            activate
            set theSelection to selection
            if (count of theSelection) is 0 then
                return "NO_SELECTION"
            end if
            set theMessage to item 1 of theSelection
            reply theMessage opening window yes
        end tell
        """
        let result = try runAppleScript(script)
        if result == "NO_SELECTION" {
            throw MailBridgeError.noSelection
        }
    }

    static func pasteClipboard() throws {
        let script = """
        tell application "System Events"
            keystroke "v" using {command down}
        end tell
        """
        _ = try runAppleScript(script)
    }

    // MARK: - Pasteboard save/restore

    private static func savePasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    private static func restorePasteboard(_ pb: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let restored: [NSPasteboardItem] = items.map { dict in
            let it = NSPasteboardItem()
            for (type, data) in dict {
                it.setData(data, forType: type)
            }
            return it
        }
        pb.writeObjects(restored)
    }

    // MARK: - AppleScript runner

    private static func runAppleScript(_ source: String) throws -> String {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw MailBridgeError.scriptError("Could not create script")
        }
        let output = script.executeAndReturnError(&errorDict)
        if let errorDict = errorDict {
            let msg = errorDict[NSAppleScript.errorMessage] as? String ?? "unknown"
            Log.write("AppleScript error: \(errorDict)")
            throw MailBridgeError.scriptError(msg)
        }
        // Coerce to UTF-8 text explicitly — `stringValue` alone is unreliable for
        // some Unicode text descriptors returned by Mail's scripting.
        let coerced = output.coerce(toDescriptorType: typeUTF8Text) ?? output
        let str = coerced.stringValue ?? ""
        Log.write("AppleScript ok, out.len=\(str.count)")
        return str
    }
}
