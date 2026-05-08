# MailMate 1.0.2 — quiet but important fixes

A maintenance release focused on three things that had been quietly broken: dictation, paste, and triage. If you tried any of those on 1.0.1 and gave up, please try them again on 1.0.2.

## Fixes

- **Microphone permission now actually sticks.** The hardened-runtime build was missing the `com.apple.security.device.audio-input` entitlement, so even when macOS showed the prompt and you clicked **Allow**, the resulting TCC entry didn't actually grant access — dictation came back as silence. The entitlement is now declared and the signed binary verifies it. After upgrading, you may need to re-grant: *System Settings → Privacy & Security → Microphone → MailMate*. If it doesn't prompt, run `tccutil reset Microphone com.toynessit.MailMate` once and trigger dictation again.

- **"Paste into Mail" no longer drops text intermittently.** App activation is partly asynchronous on Sonoma/Sequoia, so a fixed sleep before sending ⌘V was unreliable: sometimes Mail wasn't frontmost yet and the keystroke landed in another app, leaving the reply body empty. The paste flow now polls until Mail reports `frontmost=true` and has a window, addresses the keystroke at Mail's process explicitly via `tell process "Mail"`, and gives Mail a longer beat to consume the clipboard before we restore the previous contents.

- **Inbox triage no longer hangs on busy mailboxes.** The unread-fetch was using AppleScript's `messages of inbox whose read status is false`, which forces Mail to scan every message in the unified inbox — easily 60–90 seconds on a mailbox with thousands of items. The new fetch walks the most recent 300 messages by index, breaks early once it has 20 unread, and wraps the body fetch in its own `try` so a slow remote IMAP message no longer fails the whole batch. Triage now logs the fetch duration to `~/Library/Logs/MailMate.log` so future regressions are diagnosable at a glance.

## Install

If you're already on 1.0.1 with auto-update enabled, Sparkle will offer 1.0.2 the next time it checks the appcast. Otherwise, download the DMG, open it, and drag **MailMate.app** onto the Applications shortcut.

Landing page: https://hrtoyness.github.io/MailMate/
