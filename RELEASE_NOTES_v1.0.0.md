# MailMate 1.0.0 — signed, notarized, auto-updating

**First production-ready release.** Installs without any Gatekeeper warnings, without the `xattr` / right-click-Open dance. Auto-updates itself from here on out via Sparkle.

## What's new since 0.5.0

- **Proper code signing** — signed with an Apple-issued Developer ID certificate. No more ad-hoc signing.
- **Notarized by Apple** — scanned and approved for distribution. Gatekeeper launches the app without prompts.
- **Sparkle auto-updater** — menu → **Check for updates…** or automatic background checks via the appcast. Updates install in-place. No more DMG download + reinstall cycle after this release.
- **iCloud Drive rules sync** — Settings → **System** → *Sync rules via iCloud Drive* toggle. Moves your `rules.md` + `rules-overrides.md` to `~/Library/Mobile Documents/com~apple~CloudDocs/MailMate/` so they follow you across Macs on the same Apple ID.
- **Homebrew cask publisher script** — `tools/publish-cask.sh` generates a Homebrew formula from the latest release DMG. Install with `brew install --cask mailmate` once the tap is published.

## Install

Download the DMG, double-click, drag **MailMate.app** into Applications. That's it — no Setup.command step needed anymore.

## From earlier releases

Still here: Inbox triage (⌘⇧I), Draft 3 replies (⌘⇧R), Dictate a reply (⌘⇧D), Summarize thread (⌘⇧S), Dictate a task → Reminders (⌘⇧T), per-client rule overrides, calendar-aware scheduling, Nederlands + English UI, launch at login, rules-from-sent-mail generator, built-in rules editor, first-run welcome, test-connection button.

Landing page: https://hrtoyness.github.io/MailMate/
