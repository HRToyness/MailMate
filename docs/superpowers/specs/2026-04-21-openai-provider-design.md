# OpenAI / ChatGPT Provider Support — Design

## Goal

Let the user pick between Anthropic (Claude) and OpenAI (GPT) as the backend
for generating reply variants. Same UX as today; just swap the network call.

## Scope

- One shared protocol with two implementations: `AnthropicClient` (already
  exists, refactored to conform) and `OpenAIClient` (new).
- Provider + per-provider model + per-provider API key selectable in Settings.
- Keychain stores one API key per provider; both can be configured at once.
- Only the streaming 3-variant path is supported. The legacy `generateReply`
  method is unused after the streaming rework — drop it.

## Key decisions

| # | Decision | Rationale |
|---|---|---|
| 1 | Provider is a single setting (not a per-reply toggle). Switch in Settings, applies to all subsequent drafts. | Matches existing single-model mental model. Zero friction in the hot path. |
| 2 | Separate Keychain entries per provider (`anthropic-api-key`, `openai-api-key`). | User can keep both configured; switching providers doesn't erase the other key. |
| 3 | Free-text model field per provider, with sensible defaults. Defaults: `claude-sonnet-4-5` (Anthropic) and `gpt-4.1-mini` (OpenAI). | Survives model updates without code changes; matches today's Anthropic-only design. |
| 4 | Settings UI: one Picker at the top, two always-visible sections below (one per provider) each with API key + Model. | Simpler than collapsible/dependent fields. User can paste both keys once and then just toggle. |
| 5 | Persistence: add `provider` (string: `"anthropic"` / `"openai"`) to `UserDefaults`. Rename `model` → `model_anthropic`; add `model_openai`. Auto-migrate on first run. | Clean per-provider prefs, backward-compatible for existing installs. |

## Architecture

### New: `ReplyProvider` protocol

```swift
protocol ReplyProvider {
    func streamVariants(
        email: MailMessage,
        rules: String,
        onChunk: @escaping @MainActor (String) -> Void
    ) async throws -> String
}
```

Both `AnthropicClient` and `OpenAIClient` conform. `ReplyDrafter` depends on
the protocol, not a concrete type.

### `ProviderKind` enum + factory

```swift
enum ProviderKind: String, CaseIterable { case anthropic, openai }

enum ProviderFactory {
    static func make(kind: ProviderKind) -> ReplyProvider? {
        // Reads the matching key from Keychain + model from UserDefaults.
        // Returns nil if the API key for that provider is missing.
    }
}
```

`ReplyDrafter.run()` reads `UserDefaults.provider`, calls the factory, and
gets a `ReplyProvider`. Rest of the flow is unchanged.

### New: `OpenAIClient`

- Endpoint: `POST https://api.openai.com/v1/chat/completions`
- Auth: `Authorization: Bearer <api-key>`
- Body:
  ```json
  {
    "model": "...",
    "stream": true,
    "max_tokens": 2048,
    "messages": [
      {"role": "system", "content": "<system prompt>"},
      {"role": "user",   "content": "<user prompt>"}
    ]
  }
  ```
- SSE parsing mirrors the Anthropic streamer:
  - Lines starting with `data: `
  - `data: [DONE]` → break
  - Otherwise JSON-parse, pull `choices[0].delta.content`, append, emit
    `onChunk(accumulated)` on MainActor
- Error handling: on non-2xx, read body as JSON, surface
  `error.message` from OpenAI's error envelope.

### System prompt

Identical content for both providers — same `## User rules`, same
`## Always`, same `## Output format` with `===SHORT===` / `===STANDARD===` /
`===DETAILED===` delimiters. OpenAI gets it as a `role: "system"` message;
Anthropic gets it as the top-level `system` field (unchanged).

Delimiter parsing is already in `AnthropicClient.parseVariants` — move it to
a free function or `ReplyVariants.parse(...)` so both clients' consumers
don't need to reach into `AnthropicClient`.

### `KeychainHelper`

Generalize:

```swift
enum KeychainHelper {
    static func save(_ key: String, for provider: ProviderKind)
    static func load(for provider: ProviderKind) -> String?
}
```

Service stays `com.toynessit.MailMate`; account becomes
`"{provider}-api-key"` (`anthropic-api-key` / `openai-api-key`). Existing
`anthropic-api-key` entry works unchanged.

### `SettingsView`

New layout:

```
Provider  [Anthropic ▾]

── Anthropic ──────────────────────
  API key  [•••••]
  Model    [claude-sonnet-4-5]

── OpenAI ────────────────────────
  API key  [•••••]
  Model    [gpt-4.1-mini]

  [Save]                 [Edit rules file]
```

Both sections always visible; the Picker at top controls which provider is
used at draft time. Save writes all four values (both keys + both models +
provider choice).

### `ReplyDrafter`

Change one line:

```swift
let client: ReplyProvider = ProviderFactory.make(kind: currentProvider) // was: AnthropicClient(apiKey:)
```

If `make` returns nil (missing API key for the active provider), show the
existing "Set your API key in Settings" notification.

## Migration (one-time, on first launch of the new build)

```swift
// In ReplyDrafter or a dedicated migrator, run once:
let defaults = UserDefaults.standard
if defaults.string(forKey: "provider") == nil {
    defaults.set(ProviderKind.anthropic.rawValue, forKey: "provider")
}
if defaults.string(forKey: "model_anthropic") == nil,
   let legacy = defaults.string(forKey: "model") {
    defaults.set(legacy, forKey: "model_anthropic")
}
```

Keychain needs no migration — `anthropic-api-key` is already the account name.

## Out of scope (defer)

- Per-reply provider override (e.g., a menu-bar submenu to pick per-draft)
- Automatic fallback if one provider errors
- OpenAI's reasoning models (`o1`, `o3`) — these use a different API surface
  and don't support `stream` the same way; skip for now
- Azure OpenAI, any proxy/compatible-API endpoint

## Risks

- **OpenAI rate limits** — free-tier keys have low RPM; streaming 3 variants
  in one ~2KB output is usually fine, but surface a clear error if hit.
- **OpenAI `max_tokens`** — deprecated in favor of `max_completion_tokens` on
  newer models. We'll use `max_tokens` for compatibility with most 4.x
  models; if this breaks for a specific model the user can switch models.
- **Delimiter adherence** — instruction-following on the `===SHORT===`
  delimiters is slightly weaker on smaller GPT variants than on Claude
  Sonnet. Parser already falls back to "treat whole reply as Standard" if no
  markers are found; acceptable degradation.

## Files changed / added

**New:**
- `MailMate/ReplyProvider.swift` — protocol + `ProviderKind` + `ProviderFactory`
- `MailMate/OpenAIClient.swift`

**Modified:**
- `MailMate/AnthropicClient.swift` — conform to `ReplyProvider`; drop
  unused `generateReply` and `requestText`; move `parseVariants` to a free
  helper (or keep it as a static on `AnthropicClient` — both work)
- `MailMate/KeychainHelper.swift` — generalize to per-provider
- `MailMate/SettingsView.swift` — two-section layout + Picker
- `MailMate/ReplyDrafter.swift` — use factory instead of constructing
  `AnthropicClient` directly
- `build.sh` — add `ReplyProvider.swift` and `OpenAIClient.swift` to compile list

## Implementation order

1. Extract `ReplyVariants.parse` (or keep static on AnthropicClient, just
   make it callable from anywhere); remove unused `generateReply`.
2. Create `ReplyProvider` protocol + `ProviderKind` enum.
3. Make `AnthropicClient` conform (cosmetic).
4. Write `OpenAIClient` with streaming.
5. Generalize `KeychainHelper`.
6. Add `ProviderFactory`.
7. Update `ReplyDrafter` to use factory.
8. Redesign `SettingsView` + add migration on launch.
9. Update `build.sh`; rebuild; test with both providers.

Estimated ~250 new LOC, ~80 modified.
