import AppKit
import Foundation

struct MailMessage {
    let sender: String
    let subject: String
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

    /// Put `text` on the pasteboard, open a Mail reply for the currently
    /// selected message, wait for the window to settle, then synthesize Cmd+V.
    /// Setting `content` on a reply message is unreliable in recent Mail — the
    /// async population of the quoted body can clobber it. Pasting at Mail's
    /// cursor (parked above the quote) is what we want.
    static func pasteIntoReply(text: String) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Log.write("Clipboard set with reply text (len=\(text.count))")

        try openReplyWindow()
        Thread.sleep(forTimeInterval: 1.2)
        try pasteClipboard()
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
