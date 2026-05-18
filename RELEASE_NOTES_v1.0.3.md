# MailMate 1.0.3 — dictation works with AirPods

A one-fix release: voice dictation and voice tasks now work when AirPods (or any Bluetooth headset) are your microphone.

## Fixes

- **"Recorder setup failed: record() returned false" with AirPods.** The recorder hard-coded a 16 kHz / mono AAC capture format. On macOS, `AVAudioRecorder` can't reconfigure a Bluetooth input route — AirPods run HFP at 16/24 kHz and won't negotiate to an arbitrary requested format — so `record()` returned `false` and dictation failed before it started. The built-in mic (48 kHz) usually tolerated the mismatch, which is why this only bit you with AirPods connected and selected as input. The recorder now lets the active input device pick its native format instead of pinning one; it works across built-in, Bluetooth, and USB mics. Whisper accepts any sample rate (the recording is uploaded untouched), so transcription quality is unchanged.

## Install

If you're already on 1.0.2 with auto-update enabled, Sparkle will offer 1.0.3 the next time it checks the appcast. Otherwise, download the DMG, open it, and drag **MailMate.app** onto the Applications shortcut.

Landing page: https://hrtoyness.github.io/MailMate/
