# term-ai-nal

An AI-assisted terminal emulator for macOS. Native Swift and AppKit, built on
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), with an AI command
palette, an assistant sidebar, and a built-in MCP server so external agents can
read and drive its panes.

**A generated command is never executed on your behalf.** Generation only fills
in a review sheet; nothing reaches the shell until you press Execute.

macOS only. The app was an Electron/React/xterm.js project until v2; that
version is retired and deleted, preserved at the tag `electron-final`. See
[`docs/MIGRATION.md`](docs/MIGRATION.md) for the history and the current
port status.

## Requirements

- **macOS 26 or later** (`LSMinimumSystemVersion` 26.0, SwiftPM platform
  `.macOS("26.0")`).
- **Xcode is required to build.** The Apple Intelligence provider uses
  `@Generable`, and the `FoundationModelsMacros` compiler plugin ships with
  Xcode rather than the Command Line Tools. Building from the CLI is fine, but
  only with `xcode-select -p` pointing at `/Applications/Xcode.app`.
- **Apple Silicon** for the Apple Intelligence provider (and Apple Intelligence
  enabled in System Settings). Every other provider works anywhere.

## Build and run

```bash
./Scripts/make-app.sh            # debug build + .app bundle
./Scripts/make-app.sh release    # release build
open build/TermAInal.app
# or, to see stdout/NSLog:
./build/TermAInal.app/Contents/MacOS/TermAInal
```

`swift build` alone typechecks but produces only a bare executable. AppKit needs
a real bundle for the menu bar, window activation and Keychain identity, so
`Scripts/make-app.sh` hand-assembles `Contents/` with an `Info.plist`, copies in
the bundled fonts, generates the `.icns` from `Resources/AppIcon.png`, and
ad-hoc signs the result. The app is deliberately **not sandboxed** — the child
shell needs full filesystem access.

There is no `.xcodeproj`. Xcode opens `Package.swift` directly.

Note that `swift build` holds a package-wide lock, so only one build can run at
a time.

## Diagnostics

There is no test suite. These headless flags are the substitute: each one drives
real code and exits non-zero on failure, and they are the only automated
coverage in the repo.

| Flag | Verifies |
|---|---|
| `--check-ai` | Both AI profiles end to end — settings path, provider availability, discovered Ollama models, and every AI entry point. |
| `--check-contrast` | WCAG contrast of the assistant sidebar's derived colours across all built-in themes, against fixed floors. |
| `--check-titlebar` | The titlebar accessory (the assistant toggle) gets a non-zero width rather than rendering invisibly. |
| `--check-locale` | Apple Intelligence locale support — `Locale.current`, bundle localizations, `supportsLocale`, and a live request. |
| `--check-ctrld` | Ctrl+D teardown at all three levels: pane → tab → window. |
| `--check-accordion` | That expanding a pane does not recreate its terminal (which would kill the shell), that only the expanded pane is mounted, and that sessions round-trip including the older nested-split format. |
| `--check-cloud` | The Anthropic and Gemini request shape — auth header, schema placement, response decoding — against `Scripts/mock-ai-api.py`, which must be running. |

Run them against the built binary, e.g.
`./build/TermAInal.app/Contents/MacOS/TermAInal --check-ai`.

To run the last one, start the mock first:

```bash
python3 Scripts/mock-ai-api.py &
./build/TermAInal.app/Contents/MacOS/TermAInal --check-cloud
```

Not covered by any of these, and unverified at runtime: any cloud provider
against its real API (no keys have been used), and image paste rendering.

## Features

- **Tabs.** Each tab owns its own panes. Tab switching slides: the content area
  is one horizontal strip of viewport-wide tab views and selection animates its
  offset, so the direction of travel falls out of the tab order.
- **Panes as an accordion.** Within a tab, panes stack as full-width rows: one
  expanded showing its terminal, the rest collapsed to a clickable header with
  its title and shortcut. `Cmd+D` adds a row. A single pane shows no header at
  all, since a row of chrome describing the only thing on screen is noise.
  Terminals are re-parented when the stack is rebuilt rather than recreated, so
  switching panes never kills a running shell.

  This replaced a recursive tree of split groups with four split directions.
  Panes in one axis with one expanded left nothing for the tree to describe.
- **Assistant sidebar** (`Cmd+Shift+A`, or the toggle at the right of the
  titlebar — the sidebar can be closed and reopened from the same control).
  Parses OSC 133 semantic prompt marks
  out of the PTY stream into per-command records (command, cwd, exit code,
  duration, output) and comments on them *after* execution, plus free-form Q&A
  with the last few commands as context. `assistantInsights` is `off`,
  `failures` (default) or `all`.
- **Command palette** (`Cmd+Shift+P`, or the AI menu). One entry point
  with no mode: it always asks the model for a plan and renders a one-step plan
  as a single command, so the model decides how many commands a request needs.
- **Themes.** Four built-ins (`default`, `dracula`, `solarized-dark`,
  `one-dark`). The Electron iTerm `.itermcolors` importer was dropped by
  decision.
- **Session restore** (`restoreSession`, off by default). Persists the tab and
  pane layout with each pane's directory inline.
- **New-shell directory.** `newPaneDirectory` is `inherit` (default), `home` or
  `custom`; it covers both new tabs and new panes, set at spawn time rather
  than by sending a `cd`.
- **MCP server**, on by default — see below.

Panes start a `zsh --login` shell with a **freshly constructed environment**,
not the launching process's. Nothing is inherited except `SSH_AUTH_SOCK`;
`HOME`, `USER`, `PATH`, `TMPDIR`, locale and `SHELL` come from the passwd record
and the system. This is deliberate: inheriting leaked the launching session's
agent-CLI markers and credentials into every pane. The login shell rebuilds
`PATH` and your exports from `/etc/zprofile`, `~/.zprofile` and `~/.zshrc`
anyway. One accepted regression: a variable set only via `launchctl setenv`, and
never exported from a shell profile, will not reach a pane.

## AI providers

There are **two independently configurable profiles**, `commandProfile` and
`insightProfile`, each with its own provider, model, base URL and Apple model
setting:

| Profile | Used by | What matters |
|---|---|---|
| `commandProfile` | The command palette | Correct shell syntax |
| `insightProfile` | Assistant insights and Q&A | Explanation quality, low cost |

The split is measured, not speculative. On the same failing command, Apple's
on-device 3B model produced a correct diagnosis; asked to generate a command it
produced `ls -l | sort -rn | tail -n 1`, which sorts by link count and returns
the smallest file. A coder-tuned local model (`qwen3:4b`) was the reverse trade
— accurate syntax, ~2.6 GB resident. Neither is right for both jobs.

All six providers work: **`apple`** (FoundationModels, on-device),
**`anthropic`**, **`openai`**, **`gemini`**, **`perplexity`**, **`ollama`**.

`anthropic`, `openai`, `gemini` and `ollama` also accept a **Base URL**
override, for a proxy or gateway. Perplexity's endpoint is fixed and Apple has
none. Note the override means different things by necessity: for OpenAI and
Anthropic it is the complete endpoint, while for Gemini it is a host prefix,
because Gemini puts the model in the URL path and treating an override as the
whole URL would silently discard your model setting.

Model defaults, both overridable in Settings: `claude-sonnet-5` and
`gemini-2.5-flash`. Sonnet rather than Opus because generating a one-line shell
command is a small task and interactive latency matters.

Anthropic uses `output_config.format` with a JSON schema — not a forced
`tool_choice`, which current models reject with a 400, and not an assistant
prefill, which they also reject. Gemini uses `generationConfig.responseSchema`,
with `additionalProperties` stripped because Gemini's schema subset rejects it.

**Neither has been run against a live API from this machine** — no keys. Their
request shape is verified against `Scripts/mock-ai-api.py` via `--check-cloud`
(see Diagnostics); the model IDs in their defaults are unverified.

`appleModel: "pcc"` (Private Cloud Compute) is accepted but served on-device —
PCC needs macOS 27 and the current SDK exposes no way to request it.

Where a provider supports it, output shape is enforced by a JSON schema rather
than by asking in prose: guided generation via `@Generable` for Apple, Ollama's
`format` field, OpenAI's `response_format`. Perplexity has no schema and falls
back to a prose parser. Schemas fix the shape, not the content — model choice
does that.

API keys live in the login Keychain, one entry per provider
(`apiKey.<provider>`), shared between profiles pointing at the same service.
They are never written to `settings.json`. Settings live in
`~/Library/Application Support/term-ai-nal-native/settings.json`, mode `0600`.

## Keyboard shortcuts

Read from the menu definitions in `Sources/TermAInal/App/AppDelegate.swift`,
which are the authoritative source. These differ from the Electron build's:
tabs took the conventional bindings, so panes moved to `Cmd+D` and pane focus
gained `Alt`.

| Shortcut | Action |
|---|---|
| `Cmd+,` | Settings |
| `Cmd+C` / `Cmd+V` / `Cmd+A` | Copy / Paste / Select All |
| `Cmd+T` | New tab |
| `Cmd+Shift+W` | Close tab |
| `Cmd+Shift+]` / `Cmd+Shift+[` | Next / previous tab |
| `Cmd+1`–`Cmd+9` | Select tab 1–9 |
| `Cmd+D` | New pane (adds an accordion row) |
| `Cmd+W` | Close pane (closes the tab when it is the last pane) |
| `Cmd+Alt+1`–`Cmd+Alt+9` | Focus pane 1–9 |
| `Cmd+K` | Clear screen and scrollback |
| `Cmd+L` | Clear screen |
| `Cmd+Shift+P` | Command palette |
| `Cmd+Shift+A` | Toggle assistant sidebar |
| `Cmd+H` / `Cmd+Q` | Hide / quit |

Ctrl+D exits the shell and closes whatever it leaves empty: a pane, then
its tab, then the window (which quits the app).

## MCP server

A hand-rolled HTTP server on `NWListener`, bound to `127.0.0.1:57320` by default
(`mcpPort`), enabled by default (`mcpEnabled`). No SDK.

- `GET /` or `GET /mcp` — server info, including the endpoint URL.
- `POST /mcp` — JSON-RPC 2.0: `initialize`, `tools/list`, `tools/call`.
- `GET /mcp/stream?terminal_id=<id>` or `?active=true` — SSE of live output.
  Event types: `connected`, `output`, `pane_changed`, `heartbeat` (every 15 s),
  `closed`.

Tools, each individually gated by `mcpFeatures`:

| Tool | Does |
|---|---|
| `list_terminals` | Every open pane's id, label and working directory. |
| `get_terminal_output` | Buffered text of one pane, optionally the last *n* lines. |
| `get_active_terminal_output` | The same for the focused pane. |
| `send_input_to_terminal` | Write text to a pane; append `\n` to run it. |
| `watch_terminal` | Returns the SSE URL for one pane. |
| `watch_active_terminal` | Returns the SSE URL that follows the focused pane. |

Panes are exposed across **all** tabs, not just the visible one — a shell in a
background tab is still live. Output is ANSI- and OSC-stripped and kept in a
per-pane ring buffer (`mcpBufferSizeKB`, default 500 KB); overflow spills to a
temp file (`mcpFileBufferEnabled`) or is dropped.

Two things to know before relying on it. There is **no policy or audit layer**:
the server executes anything a local client asks for, which is why it is worth
turning off if you do not need it. And changing the port in Settings does not
yet restart the server — `MCPServer` is immutable per port.

## Bundled font

`Resources/Fonts/` ships four faces of **JetBrainsMonoNL Nerd Font Mono**
(~9 MB), registered at launch through `ATSApplicationFontsPath`. Registration is
scoped to the app; nothing is installed system-wide. It is bundled because the
font *fallback* stack cannot be trusted on a machine that has no Nerd Font:
Menlo is missing most of the private-use glyphs a Powerlevel10k prompt emits,
which renders them as replacement boxes. The no-ligature (`NL`) and single-width
(`Mono`) build is chosen deliberately — see the notice for why.

**Licensing:** JetBrains Mono is OFL 1.1 (`Resources/Fonts/OFL.txt`), but the
patched-in icon glyphs aggregate several upstream sets under mixed terms, some
of which **require attribution** — Font Awesome is CC BY 4.0.
[`Resources/Fonts/NOTICE.md`](Resources/Fonts/NOTICE.md) serves that purpose;
read it before distributing a build.

## Known constraints

- The target pins `swiftLanguageMode(.v5)`. Swift 6 strict concurrency has not
  been audited; `PaneController` and `AppDelegate` are main-actor by convention,
  not annotation.
- `make-app.sh` ad-hoc signs. There is no Developer ID signing, notarization or
  DMG step yet.
- Not ported from the Electron build: pane labels have no rename affordance
  (`PaneNode.label` is plumbed to MCP but nothing sets it), MCP hidden panes,
  follow-up refinement of a generated command, and the iTerm theme importer
  (dropped by decision).
- No cloud provider has been exercised against its real API. `--check-cloud`
  covers the request shape for Anthropic and Gemini; OpenAI and Perplexity have
  no equivalent.

## Licence

See [`LICENSE`](LICENSE). Bundled fonts carry their own terms, above.
