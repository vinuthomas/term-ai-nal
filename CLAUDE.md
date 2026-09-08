# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Term-AI-nal is a native AppKit terminal emulator for macOS, built on
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (`LocalProcessTerminalView` drives a
real `zsh --login` per pane). Layered on top: an AI command palette, an assistant sidebar
that comments on commands after they finish, and a built-in MCP server so external agents
can list panes, read output, stream it over SSE and send input.

The safety invariant, unchanged since the Electron build: **a generated command is never
executed on the user's behalf.** Generation only fills the review sheet; only the Execute
button writes to the shell.

The repo was an Electron/React/xterm.js app. That is retired and deleted — the tag
`electron-final` preserves it, and `docs/MIGRATION.md` records what was ported, what was
dropped by decision, and what is still missing. Doc comments throughout `Sources/` refer to
Electron files (`main.ts`, `App.tsx`, `TerminalPane.tsx`) as provenance for *why* a thing is
shaped the way it is; those files no longer exist in the tree.

## Build

Plain SwiftPM package at the repo root. No `.xcodeproj` — Xcode opens `Package.swift`
directly if you want an IDE.

- `swift build` — typecheck. Enough for most changes.
- `./Scripts/make-app.sh` — debug build plus a hand-assembled `build/TermAInal.app`.
  `./Scripts/make-app.sh release` for release. SPM emits a bare executable, and AppKit needs
  a real bundle (Info.plist, `CFBundleIdentifier`) before the menu bar, window activation
  and Keychain identity behave, so the script writes the plist, copies the bundled fonts,
  generates the `.icns` from `Resources/AppIcon.png` with `sips`/`iconutil` (cached on
  mtime), ad-hoc signs, and `touch`es the bundle so the Dock's per-path icon cache
  invalidates.
- Run with `open build/TermAInal.app`, or
  `./build/TermAInal.app/Contents/MacOS/TermAInal` to see stdout and `NSLog`.

**Xcode is required even though the build is CLI.** The Apple Intelligence provider uses
`@Generable`, whose macro plugin (`FoundationModelsMacros`) ships with Xcode and not with the
Command Line Tools, so `xcode-select -p` must point at `/Applications/Xcode.app`. The
hand-rolled `DynamicGenerationSchema` construction that avoided this is in git history if a
CLT-only build ever has to return.

Other build facts worth knowing before changing them:

- `platforms: [.macOS("26.0")]`; the target pins `swiftLanguageMode(.v5)`. The scaffold has
  not been audited for Swift 6 strict concurrency — `PaneController` and `AppDelegate` are
  main-actor by convention, not by annotation.
- The app is deliberately **not sandboxed**. The child shell needs full filesystem access.
- `swift build` holds a lock; only one build at a time, so parallel agents cannot each
  compile.
- `Resources/Fonts/` bundles JetBrainsMonoNL Nerd Font Mono (4 faces, ~9 MB), registered at
  launch via `ATSApplicationFontsPath` — scoped to the app, no system install. It is first in
  `resolveFont`'s fallback list because it is the only entry guaranteed to resolve. **NL**
  (no ligatures) because a ligature spanning two cells in a cell-addressed grid misaligns
  columns and selection; **Mono** because Nerd Font icons are double-width by default and
  would shift everything after them. `Resources/Fonts/NOTICE.md` has the mixed licensing —
  read it before shipping outside this repo.

## Verification

There is no test suite. The substitute is a set of flags on the built binary, each of which
exists because a specific bug shipped:

| flag | covers |
|---|---|
| `--check-ai` | Both AI profiles end to end: settings path, Apple availability, resolved font, that `SettingsWindowController` constructs, and every entry point (`suggestCommand`, `plan`, `answer`) on each profile. Exits non-zero listing which role failed — a working command profile says nothing about the assistant's. Run after touching anything under `AI/` or the provider settings. |
| `--check-contrast` | WCAG ratios for the assistant sidebar's derived colours across every built-in theme, against floors: body and dim text 4.5:1, accent 3:1, and a 0.029 luminance step between a card and the sidebar behind it. Exits non-zero on a violation. Run after touching `AssistantSidebarView.Palette` or adding a theme. |
| `--check-titlebar` | That the titlebar accessory gets a real width. It builds a window and calls the shipped `AppDelegate.makeSidebarToggleAccessory` factory, not a copy. Asserts the invariant (non-zero width, container wide enough) rather than a magic number, because the bug was a *zero* width. |
| `--check-locale` | How the on-device model sees the app's locale: `Locale.current`, preferred languages, the bundle's localizations, and `supportsLocale`. Exists because `Locale.current` is the user's languages *intersected with the app's own localizations*, so a bundle declaring none can resolve differently from a bare CLI binary on the same machine — a model call that fails only inside the app. |
| `--check-ctrld` | The Ctrl+D teardown chain at all three levels: a pane closes itself and the tab stays; a non-last tab closes; the last tab ends the session. Teardown runs pane → tab → window, and a break anywhere leaves dead UI rather than an error. |
| `--check-accordion` | The pane accordion: expanding a pane must not recreate its terminal (that kills the shell, and `rebuild()` now runs on *every* expand), only the expanded pane is mounted, headers stack without overlapping, and a session round-trips — including flattening the older nested-split format. Run after touching `PaneController`. |

Two things that have wasted time:

- **`Scripts/make-app.sh` kills nothing.** A running instance holds port 57320, so a rebuilt
  app fails to start its MCP server and a fixed bug looks unfixed. Quit the old instance
  first.
- The AI paths and pane reuse are unreachable from a headless check by nature; see the
  pane-reuse rule below.

## Architecture

`Sources/TermAInal/` — one executable target, ~6.8k lines. The layering is the part that
takes reading several files to see:

**`TabController` → `PaneController` → `TerminalPaneView`.** A tab owns a *whole*
`PaneController`, not a single terminal, which is why panes work inside a tab and none of
that behaviour had to be rebuilt for tabs. The tab slide is not a transition: the
content area is one horizontal strip holding every tab's view side by side, each a viewport
wide, and selecting a tab animates the strip's offset by a multiple of that width — so the
outgoing tab travels the correct direction with no direction logic anywhere. The offset is a
function of viewport width, hence recomputed on resize rather than stored.

**`PaneController` owns a flat pane list and re-parents terminal views.** Panes are an
ordered `[TerminalPaneModel]` laid out as a vertical accordion: one expanded showing its
terminal, the rest collapsed to an `AccordionHeader`. Terminals live in the `terminals`
registry keyed by pane id and are re-parented on rebuild, never recreated — **recreating
them kills the running shells**, and `rebuild()` now runs on *every* expand, so that
invariant is exercised far more than it was under splits. `--check-accordion` asserts it.

Rows are positioned by frame rather than Auto Layout, because the heights are one
expression (each collapsed pane contributes a header, the expanded one takes the rest) and
the views are reparented constantly. The cost is that resize must be observed:
`AccordionContainerView.layout()` calls back into `layoutAccordion()`.

This replaced a recursive tree of split groups with four directions, plus an `EvenSplitView`
that existed because `NSSplitView` lays reused children out at their stale frames. Both are
gone; `electron-final` and git history have them if the reasoning is ever needed.

**`TerminalPaneView` subclasses `LocalProcessTerminalView` and taps the PTY stream for two
consumers.** `OutputBuffer` (`MCP/`) gets flat ANSI-stripped text in a per-pane ring buffer,
spilling to `os.tmpdir()` past `mcpBufferSizeKB` or dropping if `mcpFileBufferEnabled` is
off; it exists solely for MCP reads, since SwiftTerm keeps its own scrollback.
`CommandLog` (`Terminal/`) parses OSC 133 semantic prompt marks (`A` prompt, `B` command
start, `C` execution, `D;<exit>`) plus `1337;CurrentDir=` into `CommandRecord`s carrying
command, cwd, output, exit code and duration — chunk-boundary safe via a per-pane carry
buffer, capped at 200 records and 256 KB each. `ANSIStripper` strips OSC as well as CSI; the
original Electron regex did not, so `ESC]1337;CurrentDir=…` leaked into every MCP read.
Per-pane cwd comes from OSC 7 when the shell reports it, else `proc_pidinfo` (`ProcessCwd`) —
not an `lsof` subprocess.

The assistant is the first consumer of `CommandLog`, and the reason it exists: "insights
after execution, not in flight" needs a command *boundary with an exit status*, which a flat
buffer cannot provide. `AssistantController` subscribes to finished commands, drops an
automatic insight rather than queueing when one is in flight (a burst must not build a
backlog of stale commentary), and answers questions with the last three commands as context.

**`MCPServer` never reads UI state.** A hand-rolled HTTP/1.1 + SSE server on `NWListener`,
`127.0.0.1:<mcpPort>` (default 57320), speaking JSON-RPC 2.0 on one endpoint. Everything it
knows arrives through injected closures — `panesProvider`, `activePaneIdProvider`,
`readBuffer`, `sendInput` — so the transport has no path into the pane tree. Tools are gated
by `settings.mcpFeatures`. Panes are exposed across *every* tab, not just the visible one: a
shell in a background tab is live and an agent may be driving it. Every tool branch returns
human-readable text, errors included, so clients never special-case failure.

**Two `AIProfile`s, not one.** `commandProfile` serves the palette (shell syntax accuracy);
`insightProfile` serves the assistant (explanation quality, low cost). The split is measured,
not speculative: on the same failing `ls`, Apple's on-device 3B diagnosed it correctly but
generated `ls -l | sort -rn | tail -n 1` for "largest file" — sorting by link count and
taking the smallest. A settings file predating the split has flat `provider`/`model`/`baseUrl`
/`appleModel` keys and **both** profiles inherit them, so an upgrade changes nothing until the
user chooses to differ. API keys are per provider (`apiKey.<provider>` in the Keychain, via
`KeychainStore`) because a key belongs to a service, not a role; the old unqualified entry is
still read as a fallback.

`AIService.provider(for:)` dispatches to `AppleIntelligenceProvider` (FoundationModels
directly, `@Generable` guided generation — no parsing layer) or `OpenAICompatibleProvider`
(openai / perplexity / ollama). Output is schema-constrained wherever the provider supports
it (Ollama's `format`, OpenAI's `response_format`); the prose parser stays as a fallback
because a schema is a strong constraint, not a proof. `ReplyCleaner` handles `<think>`
variants a schema cannot catch, because the tags land *inside* the field. Ollama gets a 300s
timeout (a cold local model can spend most of a minute loading), cloud providers 90s.

One command palette, no modes. It always asks for a plan and renders a one-step plan as a
single command, so the model decides how many commands a request needs — the user is not
asked to classify their own request first. The opener is an
`NSTitlebarAccessoryViewController` button rather than a tab-bar one, because the tab bar
hides itself at one tab, which is most of the time.

### Where things live

- `App/` — `main.swift` (the `--check-*` flags plus the hand-rolled `NSApplication`
  lifecycle, since SPM has no `@NSApplicationMain`), `AppDelegate` (window, menu with all key
  equivalents, MCP wiring, titlebar accessory), `AIPaletteController` (the review sheet).
- `Panes/` — `TerminalPaneModel`, `PaneController`/`AccordionContainerView`,
  `AccordionHeader`, `TerminalPaneView`, `ProcessCwd`, `SessionStore`, `NewPaneDirectory`.
- `Tabs/` — `TabController`, `TabBarView`.
- `Terminal/` — `CommandLog`.
- `Assistant/` — `AssistantController`, `AssistantSidebarView` (and its `Palette`, the thing
  `--check-contrast` audits).
- `AI/` — `AIService` (protocol + dispatch), the two providers, `OllamaModels` (model
  discovery via `GET {baseUrl}/api/tags`), `AIDiagnostics`, `LocaleDiagnostics`.
- `MCP/` — `MCPServer`, `OutputBuffer`/`ANSIStripper`.
- `Settings/` — `AppSettings`/`SettingsStore`, `KeychainStore`, `TerminalTheme`
  (`TerminalThemes.all`, four built-ins), `SettingsWindowController` (largest file in the
  tree).

## Conventions and hard-won rules

Each of these was learned by shipping the opposite.

- **A derived value needs an enforced floor, not a plausible formula.** Deriving sidebar
  colours by fixed blend fractions cannot work across themes: a proportional shift means
  something different on `#002b36` than on `#282a36`, and Solarized Dark's foreground is
  deliberately low-contrast to begin with. That shipped with caption text at **1.93:1** and
  card surfaces 0.012 luminance from the sidebar behind them, i.e. invisible. Hence
  `--check-contrast`.
- **The child shell environment is derived, never inherited.** `childEnvironment` builds from
  the passwd record and the system — `HOME`, `USER`, `LOGNAME`, a `PATH` seed, `TMPDIR`, the
  user's locale, our own `TERM`/`TERM_PROGRAM`, and `SHELL` from the user record rather than
  an inherited variable. Inheriting leaked the launching process's session state: started
  from a terminal running Claude Code, every pane carried `CLAUDE_CODE_CHILD_SESSION`, so
  `claude` in a pane believed it was a nested child and stopped saving transcripts
  (`CLAUDE_CODE_MESSAGING_TOKEN` is a credential besides). A denylist is the wrong shape —
  the same class covers `GEMINI_CLI`, `CODEX_SANDBOX`, `TMUX`, `STY`, `GHOSTTY_*`/`KITTY_*`/
  `WEZTERM_*`/`VSCODE_*`, `TERMINFO`, `SSH_TTY`, `SHLVL`, direnv's bookkeeping, and whatever
  ships next year; a list that must be complete to be correct will not stay complete.
  Inheriting nothing costs little because the child is a **login** shell, so `/etc/zprofile`
  (via `path_helper`), `~/.zprofile` and `~/.zshrc` rebuild PATH and the user's exports
  anyway. Two deliberate exceptions: `SSH_AUTH_SOCK` is carried over (it comes from the login
  session, cannot be derived, and losing it breaks commit signing); and a variable set only
  with `launchctl setenv` will not reach a pane — accepted, in exchange for immunity to an
  unbounded list. Do not "fix" this by adding inheritance back.
- **Do not drop a font fallback stack.** `resolveFont`'s order exists for glyph coverage, not
  taste. Falling back to `NSFont.monospacedSystemFont` rendered Powerlevel10k's private-use
  -area icons as replacement boxes; measured against the glyphs this shell's prompt emits,
  Menlo is missing 6 of 10.
- **`NSTitlebarAccessoryViewController` sizes its view from the frame and ignores Auto
  Layout's `fittingSize`.** A constraint-only container silently stays 0pt wide and the
  control renders invisibly. Set a frame; `--check-titlebar` guards it.
- **Select by key, never by index.** A control whose stored value matches no item falls
  through to index 0, and Save then persists that as the user's choice. This bug appeared
  three times in `SettingsWindowController` — it cost a user's automatic font (silently
  replaced with Andale Mono), would have rewritten an `anthropic` config to Apple, and the
  Apple-model popup's `index == 1 ? "pcc" : "on-device"` silently rewrote anything else.
  `AIProfileEditor` is immune by construction: every popup item carries its key in
  `representedObject`, selection is by key, read-back goes through
  `selectedItem?.representedObject`, and an unrecognised stored value is *appended* as
  `"<name> (not ported)"` and selected rather than discarded. Follow that pattern for any new
  control backed by a persisted string.
- **Re-verify pane reuse after touching `PaneController` view construction.** It is the most
  fragile invariant in the app and GUI automation cannot reach it (`System Events` keystrokes
  need accessibility permission the app does not have). `docs/MIGRATION.md` has the throwaway
  `--self-test-panes` harness: split, then assert object identity of the terminal view plus
  `process.running`. That is the whole test; re-add it, run it, remove it.
- **One preference covers both tabs and panes** (`newPaneDirectory`: `inherit` / `home` /
  `custom`). Each is "another shell opened from here", and having them disagree about the
  starting directory would be arbitrary. A custom path that no longer resolves falls back to
  inheriting rather than dumping the user at `/`. The directory is set on the node before
  `rebuild()`, so it reaches `startProcess(currentDirectory:)` at spawn time — the earlier
  `cd … && clear` approach left the command in shell history and flashed the wrong directory.
- **Titles are three levels, deliberately.** Window title = the fuller form (whole path with
  `~`, or a running program's own title); tab label = last path component only. Neither shows
  zsh's `user@host:path` verbatim, because the user and host never change and spend a
  titlebar saying nothing — `normalisedTitle` keeps the path and passes a program's own title
  (no `@` before the colon) through untouched. Tabs are restored before the window exists, so
  `refreshSelectedTitle()` must be called after `buildWindow()` or the first notification is
  dropped.
- **Settings live in `term-ai-nal-native/`, not `term-ai-nal/`.** The latter is the Electron
  app's old `userData`; the native store imports it once, read-only, on first run. The doc
  comment still frames this as "until Electron is retired" — Electron is now retired, but the
  directory name is where every dogfooding user's real settings are, so renaming it would
  silently reset them.
- Settings are read fresh from disk in hot paths (buffer sizing on every append) rather than
  cached. Cheap enough, but keep it in mind before adding work to `load()`. Any load failure
  yields defaults rather than throwing, so a corrupt file can never block startup, and every
  key falls back individually so an older file still loads.
- **JSON-RPC ids: check `CFBooleanGetTypeID` before `as Bool`.** `JSONSerialization` returns
  `NSNumber` for JSON numbers and ObjC bridging makes `as Bool` match any `NSNumber`, so the
  id `1` came back as `true`.
- **Prompt hygiene, both measured.** zsh's `PROMPT_SP` (`%` plus padding) lands before the
  OSC 133 `D` mark on this machine and so falls inside the command's own output; it is
  trimmed at record close, since it is pure wasted context once records go to a model. And
  small models over-use an escape hatch: offering "reply NOTHING if there is nothing to say"
  got it used on a failing `ls`, the exact case the feature exists for, so the opt-out is now
  offered only for commands that succeeded. The on-device model's context window is 4096
  tokens and glyph-heavy terminal output costs roughly a token per character, so output fed
  to it must be reduced, not passed through.

## Shortcuts

`Cmd+T` new tab · `Cmd+Shift+W` close tab · `Cmd+Shift+]`/`[` next/previous tab ·
`Cmd+1`–`9` select tab · `Cmd+D` new pane · `Cmd+Alt+1`–`9` expand pane · `Cmd+W` close pane
(closes the tab when it is the last pane) · `Cmd+K` clear screen and scrollback · `Cmd+L`
clear screen · `Cmd+Shift+P` command palette · `Cmd+Shift+A` toggle assistant sidebar ·
`Cmd+,` settings · `Cmd+C`/`Cmd+V`/`Cmd+A` copy / paste / select all.

These are `NSMenuItem` key equivalents, which is why they do not fire while a text field has
focus. They differ from the Electron build: tabs took the conventional bindings (`Cmd+T`,
`Cmd+1`–`9`), so panes moved to `Cmd+D` and pane focus to `Cmd+Alt+1`–`9`. The four split
directions are gone with the split tree — there is one axis now.

Copy and Select All use the standard responder-chain selectors that SwiftTerm's
`TerminalView` already implements, which is why they need no custom handling.

## Known gaps

Do not assume these work; `docs/MIGRATION.md` is the authoritative list.

- **All six providers are wired** (`apple`, `anthropic`, `openai`, `gemini`, `perplexity`,
  `ollama`), but **no cloud provider has been run against its real API** — there are no keys
  on this machine. `--check-cloud` plus `Scripts/mock-ai-api.py` covers the request shape for
  Anthropic and Gemini (auth header, schema placement, decoding); OpenAI and Perplexity have
  no equivalent. The model IDs in the defaults are unverified. When touching a cloud provider,
  note that each carries the shared `AISchemas` to a different mechanism, and that Anthropic
  rejects three patterns an older prior would reach for: forced `tool_choice`, an assistant
  prefill, and the deprecated top-level `output_format`.
- **Private Cloud Compute**: `appleModel: "pcc"` is accepted but served on-device. The SDK
  exposes no way to request PCC; the TODO deliberately does not fake it.
- **Image paste** is implemented (clipboard image → PNG → iTerm2 OSC 1337 `File=`, falling
  back to a text paste) but has never been visually confirmed.
- **Pane labels** — `PaneNode.label` is plumbed through to MCP but nothing sets it.
- **MCP hidden panes** — hiding is expressed only by omitting a pane from `panesProvider`;
  the distinct 403 "not visible to MCP" response collapsed into a 404.
- **MCP restart on settings change** — `MCPServer` is immutable per port, so changing the
  port or the enabled flag needs `stop()` plus a fresh instance. Not wired up.
- **Follow-up refinement** of a generated command is not implemented.
- **iTerm theme import is dropped by decision.** Four built-ins only;
  `customTheme`/`customThemeName` are deliberately absent from `AppSettings`.
- Signing, notarization and DMG packaging do not exist yet — `make-app.sh` ad-hoc signs.
  A real build needs a Developer ID, hardened-runtime entitlements (but *not* the sandbox),
  and `notarytool`.

## Release Process

**Never automatically push commits or create GitHub releases without explicit human
approval.** Stop after building the app and ask the user to test it. Only push to git and
create a GitHub release after the user has tested and confirmed the build works.
