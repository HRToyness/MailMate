# MailMate 1.0.1 — polished installer + correctness fixes

A small but worthwhile follow-up to 1.0.0. The DMG is now genuinely click-and-go, and a handful of quiet bugs have been swept up.

## What's new

- **Polished install window** — branded dark-gradient background with a "Drag MailMate to Applications" arrow, large icons positioned for you, no Finder toolbar/sidebar clutter. Open the DMG and you immediately see what to do.
- **Setup.command and README dropped from the DMG** — both existed only to work around the unsigned-app Gatekeeper dance. Now that the app is signed and notarized by Apple, neither is needed. First impression on download matches the install reality.
- **Default Anthropic model bumped to `claude-sonnet-4-6`.** New installs get the current Sonnet out of the box; existing users keep whatever they had set.

## Fixes

- **Xcode build no longer fails with "Invalid redeclaration of 'SparkleUpdater'."** The two Sparkle files now use `#if canImport(Sparkle)` / `#if !canImport(Sparkle)` guards, so they coexist safely whether or not `vendor/Sparkle.framework` is configured.
- **Version is now a single source of truth.** `MARKETING_VERSION` lives in `project.yml`; `build.sh` reads it at build time. Previously an Xcode-generated build would bake in `0.1.0` and then immediately offer to "update" itself to the appcast version.
- **README cleanup** — removed the "stable code-signing identity" line from the roadmap (we have one now), and the description of the DMG no longer mentions the gone Setup.command step.

## Install

Download the DMG, double-click, drag **MailMate.app** onto the Applications shortcut. That's it.

If you're already on 1.0.0 with auto-update enabled, Sparkle will offer 1.0.1 the next time it checks the appcast.

Landing page: https://hrtoyness.github.io/MailMate/
