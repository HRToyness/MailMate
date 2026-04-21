# Three Reply Variants — Design

## Goal

Replace the current single-reply flow with one that generates **three labeled reply variants** (Short, Standard, Detailed) and lets the user pick which one lands in Mail's reply window.

## Flow

1. User triggers the action via the status-bar menu item or Services shortcut.
2. App reads the selected Mail message (unchanged from current).
3. App calls Anthropic once with a system prompt instructing the model to
   return three variants, delimited by `===SHORT===`, `===STANDARD===`,
   `===DETAILED===` markers.
4. App parses the response into three strings.
5. A floating SwiftUI panel appears centered on screen with three cards
   side-by-side. Each card shows: a label header, the full reply text in a
   scrollable text view, and a **Use this** button. The panel also supports
   **Esc** to cancel.
6. When the user picks a card, that text is copied to the clipboard, Mail's
   reply window is opened via AppleScript, `Cmd+V` is synthesized via
   System Events, and the panel closes.

## Components

- **`AnthropicClient.generateVariants(email:rules:) -> (short: String, standard: String, detailed: String)`**
  - New system prompt appends a "Format" section asking for the three
    delimiter-bracketed variants.
  - Parses output on the three delimiters. If parsing fails (no delimiters
    found), returns the full body as `standard` with empty `short` and
    `detailed`; the panel then renders a single card.
- **`VariantPanel.swift`** (new)
  - A `NSWindowController` holding an `NSHostingController` with a SwiftUI
    view showing three `VariantCard`s in an `HStack`.
  - Takes an `onPick: (String) -> Void` closure.
  - Dismisses itself when a card is picked or Esc is pressed.
- **`MailBridge`**
  - Split the existing `createReplyDraft(withPrependedText:)` into two ops:
    `openReplyWindow()` (AppleScript that opens Mail's reply window and
    activates Mail) and `pasteClipboard()` (System Events Cmd+V). The
    variant flow puts the chosen text on the clipboard, opens the reply
    window, waits, then pastes.
  - The old combined `createReplyDraft` stays for backwards compatibility
    but is no longer called.
- **`ReplyDrafter.run()`**
  - Replaces the current single-call branch. After reading the message and
    loading rules, calls `generateVariants`, then instantiates
    `VariantPanel` on the main actor with an `onPick` handler that runs the
    clipboard+paste sequence.
- **`StatusController`**
  - Menu item title changes from "Draft reply for selected message" to
    "Draft 3 reply options…". Same selector.

## System prompt addendum

After the existing `## Always` block, append:

```
## Output format
Return EXACTLY three variants, each preceded by the marker on its own line:

===SHORT===
<a terse 1-2 sentence reply, direct and to the point>

===STANDARD===
<a normal-length reply that follows the rules above>

===DETAILED===
<a longer reply that addresses points more thoroughly, adds relevant caveats,
 and may include structure like short paragraphs or a list>

Do NOT include any text outside these three sections. Do not add preamble.
```

## Error handling

- API error → existing notification flow, no panel shown.
- Parsing error (no delimiters in response) → panel opens with a single card
  containing the raw body, labeled "Reply".
- `AppleScript` error during open-reply or paste → existing notification
  flow. The panel stays up so the user can retry or cancel.

## Out of scope (for this iteration)

- Regeneration from within the panel.
- Editing a variant before pasting.
- Remembering which variant the user usually picks.
- Keyboard shortcuts (1/2/3 to pick) — nice-to-have, can add later.
