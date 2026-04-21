# MailMate — Build Spec for Claude Code

Native macOS menu bar app that reads the selected Mail.app message, drafts a reply using the Anthropic API following user rules, and opens a reply draft in Mail. Triggered by a user-assigned keyboard shortcut via macOS Services.

> Rename the app/bundle ID to your preference — this spec uses `MailMate` and `com.toynessit.MailMate`.

## Stack

- Swift 5.9+, macOS 14 (Sonoma) target
- SwiftUI for Settings, AppKit for menu bar + Services
- `NSAppleScript` for Mail bridge (no ScriptingBridge — less ceremony)
- `URLSession` for Anthropic API (no SDK)
- Keychain for API key storage
- `~/Library/Application Support/MailMate/rules.md` for user-editable rules

## Flow

1. User selects a message in Mail, presses shortcut (bound to the Service)
2. App activates → reads selected message via AppleScript
3. Loads rules from `rules.md`
4. Calls Anthropic `/v1/messages` with rules as system prompt + email as user message
5. AppleScript opens a Mail reply draft with generated text prepended to the quoted original
6. User reviews, edits, sends

## Project structure

```
MailMate/
├── MailMate.xcodeproj
├── MailMate/
│   ├── MailMateApp.swift
│   ├── AppDelegate.swift
│   ├── StatusController.swift
│   ├── ReplyDrafter.swift
│   ├── MailBridge.swift
│   ├── AnthropicClient.swift
│   ├── RulesLoader.swift
│   ├── KeychainHelper.swift
│   ├── SettingsView.swift
│   ├── Info.plist
│   └── MailMate.entitlements
└── README.md
```

## File contents

### `MailMateApp.swift`

```swift
import SwiftUI

@main
struct MailMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}
```

### `AppDelegate.swift`

```swift
import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusController: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusController()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    // Called by macOS when the Service is invoked.
    // NSMessage in Info.plist must match this selector name.
    @objc func draftAIReply(_ pboard: NSPasteboard,
                            userData: String,
                            error: NSErrorPointer) {
        Task { @MainActor in
            await ReplyDrafter.shared.run()
        }
    }
}
```

### `StatusController.swift`

```swift
import AppKit

class StatusController {
    private var statusItem: NSStatusItem!

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "envelope.badge",
            accessibilityDescription: "MailMate"
        )

        let menu = NSMenu()

        let draftItem = NSMenuItem(
            title: "Draft reply for selected message",
            action: #selector(draft),
            keyEquivalent: "r"
        )
        draftItem.keyEquivalentModifierMask = [.command, .shift]
        draftItem.target = self
        menu.addItem(draftItem)

        menu.addItem(.separator())

        let rulesItem = NSMenuItem(title: "Edit rules…",
                                   action: #selector(editRules),
                                   keyEquivalent: "")
        rulesItem.target = self
        menu.addItem(rulesItem)

        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(openSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MailMate",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func draft() {
        Task { @MainActor in
            await ReplyDrafter.shared.run()
        }
    }

    @objc private func editRules() {
        RulesLoader.openInEditor()
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
```

### `ReplyDrafter.swift`

```swift
import AppKit
import UserNotifications

@MainActor
final class ReplyDrafter {
    static let shared = ReplyDrafter()

    func run() async {
        guard let apiKey = KeychainHelper.load(), !apiKey.isEmpty else {
            notify("Set your Anthropic API key in Settings.")
            return
        }

        do {
            let email = try MailBridge.getSelectedMessage()
            notify("Drafting reply…")

            let rules = RulesLoader.load()
            let client = AnthropicClient(apiKey: apiKey)
            let reply = try await client.generateReply(email: email, rules: rules)

            try MailBridge.createReplyDraft(withPrependedText: reply)
        } catch MailBridgeError.noSelection {
            notify("Select a message in Mail first.")
        } catch {
            notify("Error: \(error.localizedDescription)")
        }
    }

    private func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "MailMate"
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content,
                                        trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
```

### `MailBridge.swift`

```swift
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
        // If body contains the separator, rejoin the tail
        let body = parts[2...].joined(separator: separator)
        return MailMessage(sender: parts[0], subject: parts[1], body: body)
    }

    static func createReplyDraft(withPrependedText text: String) throws {
        // Escape for embedding in AppleScript literal
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Mail"
            set theSelection to selection
            if (count of theSelection) is 0 then
                return "NO_SELECTION"
            end if
            set theMessage to item 1 of theSelection
            set replyMsg to reply theMessage opening window yes
            delay 0.6
            tell replyMsg
                set currentBody to content
                set content to "\(escaped)" & return & return & currentBody
            end tell
            activate
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
            throw MailBridgeError.scriptError(msg)
        }
        return output.stringValue ?? ""
    }
}
```

### `AnthropicClient.swift`

```swift
import Foundation

struct AnthropicClient {
    let apiKey: String
    var model: String = "claude-sonnet-4-5"
    var maxTokens: Int = 1024

    func generateReply(email: MailMessage, rules: String) async throws -> String {
        let systemPrompt = """
        You are an email assistant drafting reply bodies on behalf of the user.

        ## User rules
        \(rules)

        ## Always
        - Reply in the SAME LANGUAGE as the incoming email (detect from the body, not the sender name).
        - Match the sender's level of formality.
        - If a concrete commitment (date, price, meeting, deliverable) is implied, flag it with [CONFIRM] inline rather than committing.
        - Keep it concise — no filler, no "I hope this email finds you well".
        - Output ONLY the reply body. No subject line. No signature — Mail.app appends the user's signature automatically.
        - Do not include any quoted original text or "On <date>, X wrote:" — the draft already has that.
        """

        let userPrompt = """
        From: \(email.sender)
        Subject: \(email.subject)

        \(email.body)
        """

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Anthropic", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errBody)"])
        }

        struct APIResponse: Decodable {
            struct Content: Decodable {
                let type: String
                let text: String?
            }
            let content: [Content]
        }

        let decoded = try JSONDecoder().decode(APIResponse.self, from: data)
        let text = decoded.content.first(where: { $0.type == "text" })?.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

### `RulesLoader.swift`

```swift
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
```

### `KeychainHelper.swift`

```swift
import Foundation
import Security

enum KeychainHelper {
    private static let service = "com.toynessit.MailMate"
    private static let account = "anthropic-api-key"

    static func save(_ key: String) {
        let data = key.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

### `SettingsView.swift`

```swift
import SwiftUI

struct SettingsView: View {
    @State private var apiKey: String = KeychainHelper.load() ?? ""
    @State private var savedFlash = false
    @State private var model: String = UserDefaults.standard.string(forKey: "model") ?? "claude-sonnet-4-5"

    var body: some View {
        Form {
            Section {
                SecureField("Anthropic API key", text: $apiKey)
                TextField("Model", text: $model)
                    .help("e.g. claude-sonnet-4-5")
            }

            HStack {
                Button("Save") {
                    KeychainHelper.save(apiKey)
                    UserDefaults.standard.set(model, forKey: "model")
                    savedFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { savedFlash = false }
                }
                if savedFlash {
                    Text("Saved").foregroundColor(.green).font(.caption)
                }
                Spacer()
                Button("Edit rules file") {
                    RulesLoader.openInEditor()
                }
            }
        }
        .padding()
        .frame(width: 460, height: 200)
    }
}
```

### `Info.plist` (merge with the Xcode-generated one)

```xml
<key>LSUIElement</key>
<true/>
<key>NSAppleEventsUsageDescription</key>
<string>MailMate reads the selected Mail message and creates a reply draft.</string>
<key>NSUserNotificationsUsageDescription</key>
<string>MailMate shows brief status notifications.</string>
<key>NSServices</key>
<array>
    <dict>
        <key>NSMenuItem</key>
        <dict>
            <key>default</key>
            <string>MailMate/Draft AI reply</string>
        </dict>
        <key>NSMessage</key>
        <string>draftAIReply</string>
        <key>NSPortName</key>
        <string>MailMate</string>
    </dict>
</array>
```

### `MailMate.entitlements`

Disable App Sandbox for v1 (sandboxed apps need extra entitlements for Apple Events which complicates things). You can add sandbox later.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
</dict>
</plist>
```

## Xcode setup (Claude Code, do this)

1. Create a new Xcode project: macOS → App → App Name `MailMate`, Interface SwiftUI, Language Swift, Bundle ID `com.toynessit.MailMate`.
2. Set Deployment Target: macOS 14.0.
3. In Signing & Capabilities: disable App Sandbox. Team: user's personal team (signing can be "Sign to Run Locally" for dev).
4. Replace generated files with the files above.
5. In Info.plist, add the keys above (merge, don't overwrite Xcode's defaults).
6. Set the entitlements file in Build Settings → Code Signing Entitlements.

## Post-build setup (user steps, include in README.md)

1. Build and run once in Xcode (menu bar icon appears — an envelope).
2. Click the icon → Settings → paste Anthropic API key, click Save.
3. Click icon → "Edit rules…" → edit `rules.md` with your tone/rules.
4. First time you use it, macOS will prompt: "MailMate wants to control Mail". Allow it. (Can re-enable later in System Settings → Privacy & Security → Automation.)
5. Open **System Settings → Keyboard → Keyboard Shortcuts → Services** → find "MailMate/Draft AI reply" under "General" → bind a shortcut (e.g. ⌘⇧R). Might require enabling it if disabled.
6. In Mail.app, select a message → press your shortcut → reply window opens with drafted text above the quoted original.

## Notes & gotchas

- **Services cache**: if the Service doesn't appear after first build, run `/System/Library/CoreServices/pbs -flush` in Terminal or log out/in. Running the app at least once registers it.
- **AppleScript delay**: the `delay 0.6` in reply creation gives Mail time to populate the reply window body before we prepend. Tune if needed.
- **Long emails**: `max_tokens: 1024` is enough for typical replies. Bump in Settings if you're drafting longer responses.
- **Rate limiting / offline**: no retry logic in v1; API errors surface as notifications. Add retry when it matters.
- **Model selection**: default `claude-sonnet-4-5` is plenty for email drafting. Switch to `claude-opus-4-7` via Settings for higher-stakes messages.
- **Thread context**: v1 only sends the selected message, not the full thread. If you need thread context, extend `MailBridge.getSelectedMessage` to walk `messages of mailbox of theMessage` or use `content of theMessage` which in Mail includes quoted history.

## Claude Code prompt to run

In an empty directory, run `claude` then paste:

> Build the macOS Swift menu bar app described in `MAILMATE_BUILD_SPEC.md` (attached). Create the Xcode project, all Swift files, Info.plist additions, and entitlements exactly as specified. Name the project MailMate, bundle id `com.toynessit.MailMate`, deployment target macOS 14. Don't add features beyond the spec — we'll iterate after first build.

Save the spec as `MAILMATE_BUILD_SPEC.md` in the same directory first so Claude Code can read it.

## After v1 works, likely next steps

- Preview window: show the drafted reply in a small floating window before opening in Mail, with "Open in Mail / Regenerate / Cancel" buttons.
- Thread-aware drafting: pass the last N messages in the thread to the API.
- Multiple rule profiles (client-specific): switch rule sets based on sender domain.
- Prompt tuning: per-sender tone overrides loaded from a simple table in Settings.
