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
