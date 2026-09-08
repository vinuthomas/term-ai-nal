# Electron → native Swift migration

**The migration is complete.** The Electron app has been retired and deleted;
the tag `electron-final` preserves its last state, recoverable with:

```bash
git checkout electron-final -- src package.json vite.config.ts tsconfig.json
```

The Swift package now sits at the repo root. This document is kept as the record
of how the port was done, what was deliberately dropped, and — most usefully —
the bugs that were shipped along the way and the disciplines that came out of
them. `CLAUDE.md` carries the rules; this is the reasoning behind them.

## Build

```bash
./Scripts/make-app.sh          # debug build + .app bundle
./Scripts/make-app.sh release  # release build
open build/TermAInal.app
# or, to see stdout/NSLog:
./build/TermAInal.app/Contents/MacOS/TermAInal
```

**Xcode is required**, even though the build is a CLI one: the `@Generable`
macro the Apple provider uses is expanded by `FoundationModelsMacros`, which
ships with Xcode and not with the Command Line Tools, so `xcode-select -p` must
point at `Xcode.app`. (This started as a CLT-only build; see Known constraints.)

The package is plain SPM and `Scripts/make-app.sh` hand-assembles the `.app`
with an `Info.plist`, because SPM emits a bare executable and AppKit needs a
real bundle for its menu bar, window activation and Keychain identity.
`swift build` alone typechecks. There is no `.xcodeproj`; Xcode opens
`Package.swift` directly.

The app is deliberately **not sandboxed** — SwiftTerm's child shell needs full
filesystem access.

There is no test suite. Five flags on the built binary stand in for one, and
each exists because a specific bug shipped:

| flag | guards against |
|---|---|
| `--check-ai` | a provider profile that cannot answer; exercises both roles |
| `--check-contrast` | derived theme colours falling below their contrast floors |
| `--check-titlebar` | a titlebar accessory sized from Auto Layout, which renders at zero width |
| `--check-locale` | the on-device model's locale support and the token cost of a real context |
| `--check-ctrld` | the pane → tab → window teardown chain leaving dead UI |

A running instance holds port 57320. A stale one has previously made a fixed
bug look unfixed, so check for it before concluding anything from a probe.

`make-app.sh` also generates the app icon, because nothing else does it now:
electron-builder handled that for the Electron target, and the hand-assembled
bundle initially had no `CFBundleIconFile` at all, so the Dock showed the
generic placeholder. It builds a full iconset from `Resources/AppIcon.png` with `sips`
and `iconutil` rather than reusing the repo's `build/icon.icns`, which contains
only a single 1024pt representation. The bundle is `touch`ed afterwards, since
the Dock and Finder cache icons per bundle path and a rebuild in place otherwise
keeps showing the previous one.

## What is done

| Area | Electron original | Native replacement |
|---|---|---|
| Terminal + PTY | `node-pty` + xterm.js | `SwiftTerm.LocalProcessTerminalView` |
| Pane tree | `LayoutNode` in `App.tsx` | `PaneNode` + `PaneController` |
| Pane reuse across relayout | module-level `globalTerminals` map | `PaneController.terminals` registry |
| Shortcuts | one global `keydown` handler | `NSMenuItem` key equivalents |
| Window chrome | `titleBarStyle: 'hiddenInset'` | `fullSizeContentView` + transparent titlebar |
| cwd per pane | `lsof` subprocess per call | OSC 7, falling back to `proc_pidinfo` |
| Output buffer + spill | `appendToBuffer` / `getBufferLines` | `OutputBuffer` |
| MCP server | hand-rolled `http.createServer` | `MCPServer` on `NWListener` |
| Settings | `settings.json`, mode 0600 | `AppSettings` + `SettingsStore` |
| API key | Electron `safeStorage` hex blob | login Keychain via `KeychainStore` |
| AI: Apple | shell out to `/usr/bin/fm` | **FoundationModels framework directly** |
| AI: OpenAI/Perplexity/Ollama | `callAIRaw` branches | `OpenAICompatibleProvider` |
| Command review overlay | React overlay | `AIPaletteController` sheet |

The safety invariant is preserved verbatim: **a generated command is never
executed on the user's behalf.** Generation only populates the review sheet;
only the Execute button writes to the shell.

### Verified working
- App launches, opens a `zsh --login` pane, splits, closes, renumbers panes.
- MCP server answers on `127.0.0.1:57320`; `GET /mcp`, `tools/list`,
  `tools/call` all respond.
- Full round trip: `send_input_to_terminal` → shell executes →
  `get_terminal_output` returns the result as clean text.
- Settings window constructs with all three tabs; themes and fonts apply to
  live panes on Save.
- **Ollama end to end**: model discovery via `/api/tags`, plus `suggestCommand`
  and `plan` both returning correct output with `qwen2.5-coder:14b`.
- Apple Intelligence availability probe reports correctly, and with the feature
  enabled the **`@Generable` round trip works** — guided generation returns a
  typed result with no parsing layer at all.
- **Session restore**: a saved two-pane layout comes back with directories and
  labels intact and fresh pane ids, and a graceful quit re-saves live
  directories.

Run `TermAInal --check-ai` for a headless check of the configured provider —
it prints the settings path, availability, discovered Ollama models, and
exercises both AI entry points. The AI layer is otherwise only reachable by
driving the UI.

### Not verified
- **OpenAI / Perplexity.** Need a real key. The `response_format` JSON-schema
  branch for OpenAI is written but unexercised.
- **Image paste rendering.** The escape sequence is emitted and SwiftTerm
  supports the protocol, but nobody has watched an image appear.

### Provider quality, measured

Same two prompts, via `--check-ai`:

| provider | command produced | verdict |
|---|---|---|
| `qwen3:4b` (Ollama) | `ls -lhS` | correct |
| `qwen2.5-coder:14b` | `ls -lhS` | correct, ~9 GB resident |
| Apple on-device (3B) | `ls -l \| sort -rn \| tail -n 1` | wrong — sorts by link count, `tail` takes the smallest |
| DeepSeek-R1-Distill-1.5B | `ls -d` | unusable |

Apple's model is free, instant and costs no resident RAM, but it is weaker at
shell syntax — Apple deprioritises code for it deliberately. This is the
argument for the **tiered** design: the on-device model for the cheap, frequent,
structured work (summarising output, explaining a failure, labelling panes) and
a coder-tuned model for actually generating commands. The default ships as
Ollama + `qwen3:4b`; switch in Settings.

## Improvements over the Electron build

These were fixed during the port rather than carried across:

1. **Guaranteed AI response shapes.** `callAI` asked for
   `COMMAND: …/EXPLANATION: …` in prose and split the string; `callAIPlan` asked
   for a bare JSON array and ran `JSON.parse`. Both broke on a stray code fence.
   The Apple provider now uses guided generation, so the shape is enforced by a
   schema and the parsing layer is gone. The 10-step plan cap became a schema
   constraint instead of prompt guidance.
2. **No `lsof` per pane.** `ProcessCwd` reads the working directory from the
   kernel with `proc_pidinfo`.
3. **OSC sequences are stripped.** The `ANSI_RE` regex only covered CSI escapes,
   so with shell integration active (iTerm2's, or OSC 133) sequences like
   `ESC]1337;CurrentDir=…` leaked into every MCP read. `ANSIStripper` handles
   OSC too.
4. **API key never touches disk in app storage.** It lives in the Keychain
   rather than as a `safeStorage` blob inside `settings.json`.
5. **Schema-constrained output for Ollama and OpenAI too.** Concrete evidence
   this was needed: asked in prose for no backticks, a 1.5B model returned
   `` `ls -u | sort -u` `` — markdown inside the command, exactly the breakage
   the Electron parser lived with. Ollama's `format` field and OpenAI's
   `response_format` now carry a JSON schema, so every provider except
   Perplexity gets a guaranteed shape. The prose parser stays as a fallback,
   since a schema is a strong constraint rather than a proof and some servers
   ignore the field.

   Worth knowing: the schema fixed the *format* but not the *content*. The same
   1.5B model then produced `ls -lz`, an invented flag; `qwen2.5-coder:14b`
   produced `ls -lhS`. Schema fixes shape, model choice fixes correctness.
6. **Native settings are isolated from the Electron app's.** The native store
   originally resolved to `~/Library/Application Support/term-ai-nal/`, which is
   the *live Electron userData directory*. Because `save()` writes only the keys
   `AppSettings` knows about, saving from the native UI would have silently
   stripped `apiKey`, `customTheme` and `customThemeName` from the shipping
   app's config. The native app now uses `term-ai-nal-native/` and imports the
   Electron file once, read-only, on first run.
7. **JSON-RPC id fidelity.** A bug found during the port: `JSONSerialization`
   returns `NSNumber` for JSON numbers and `as Bool` matches any `NSNumber`
   through ObjC bridging, so the id `1` came back as `true`. Fixed by checking
   `CFBooleanGetTypeID` first. Worth checking whether the TS side has an
   analogous coercion problem.

## Not yet ported

Ordered roughly by how much they'd be missed.

- **Settings UI.** `Settings.tsx` has no counterpart; `settings.json` is read at
  launch and the menu item shows a placeholder. Everything else in the settings
  layer is done, so this is pure AppKit form-building.
- **Session restore.** `session.json`, the layout/cwd persistence, and the
  `before-quit` cwd refresh are not implemented. `restoreSession` is parsed and
  ignored.
- **Themes.** `themes.ts`' four built-ins and `parseItermTheme` are absent; the
  terminal uses SwiftTerm's defaults. `customTheme`/`customThemeName` are
  omitted from `AppSettings` rather than stored and unused.
- ~~**Anthropic and Gemini providers.**~~ **Done** — all six providers are
  wired. Neither has been run against a live API from this machine; see
  "Cloud providers" below.
- **Private Cloud Compute.** `appleModel: "pcc"` is accepted but served
  on-device. PCC needs macOS 27; the 26.5 SDK exposes no way to request it. The
  TODO deliberately does not fake it.
- **Follow-up refinement** of a generated command (the Electron overlay's
  refine box).
- **Image paste** (`pasteImageToTerminal`) and the xterm image addon.
- **Pane labels.** `PaneNode.label` exists and is surfaced over MCP but nothing
  sets it.
- **MCP hidden panes.** Hiding is now expressed by omitting a pane from
  `panesProvider`; there is no UI to mark one hidden, and the distinct 403
  "not visible to MCP" response collapsed into a 404.
- **MCP restart on settings change.** `applyMcpSettings` watched for port
  changes; `MCPServer` is immutable per port, so this needs `stop()` plus a new
  instance when the settings UI lands.
- **Font settings.** `fontSize`/`fontFamily` are parsed but not applied.

## Porting traps hit so far

Two regressions that only showed up in real use, both from trusting a library
default over what the Electron build actually did:

1. **A minimal child environment.** `Terminal.getEnvironmentVariables` returns
   only TERM, COLORTERM, LANG and a few of USER/HOME/LOGNAME — PATH is
   explicitly excluded. The Electron build spawned with `{...process.env}`, and
   iTerm2 and Terminal.app inherit too. With `SHELL` absent, zsh startup scripts
   took a bash code path and emitted `(eval):type: bad option: -t`, which then
   tripped Powerlevel10k's instant-prompt warning on every launch. The child now
   inherits the full environment, with TERM/COLORTERM/SHELL set explicitly and
   LANG only as a fallback. Went from 6 variables to 60.
2. **Inheriting the launcher's environment at all.** The fix above went the
   other way and handed the child everything, including state describing the
   process that launched the app. Started from a terminal running Claude Code —
   which is how it launches during development — every pane inherited that
   session's markers, so `claude` run inside a pane saw
   `CLAUDE_CODE_CHILD_SESSION`, concluded it was a nested child and silently
   stopped saving transcripts. `CLAUDE_CODE_MESSAGING_TOKEN` is a credential
   besides.

   A denylist of known offenders was the obvious next move and the wrong shape.
   The same class covers Gemini CLI's `GEMINI_CLI`, Codex's `CODEX_SANDBOX`
   (where a stale value could persuade a tool it is already sandboxed), `TMUX`,
   `STY`, every host terminal's `GHOSTTY_*` / `KITTY_*` / `WEZTERM_*` /
   `VSCODE_*`, `TERMINFO`, `SSH_TTY`, `SHLVL`, direnv's bookkeeping — and
   whatever ships next year. A list that must be complete to be correct will
   not stay complete.

   So **nothing is inherited**. `childEnvironment` builds from the user record
   and the system: `HOME`, `USER`, `LOGNAME`, a `PATH` seed, `TMPDIR`, the
   user's locale, our own `TERM`/`TERM_PROGRAM`, and `SHELL` read from the
   passwd record rather than an inherited variable. This costs less than it
   appears to, because the child is a **login** shell — `/etc/zprofile` via
   `path_helper`, `~/.zprofile` and `~/.zshrc` rebuild PATH and the user's
   exports regardless. Verified: with fourteen markers planted in the parent,
   including a `SOME_FUTURE_AGENT_SESSION` no code mentions, none reached the
   pane; `SHLVL=1`, `TERM_PROGRAM=term-ai-nal`, and `claude`, `gemini`,
   `ollama`, nvm-managed `node`, `brew` and `swift` all still resolve.

   Two deliberate exceptions. `SSH_AUTH_SOCK` is carried over, because the
   agent socket comes from the login session, cannot be derived, and losing it
   breaks commit signing and pushes. And a variable placed in the GUI session
   with `launchctl setenv`, never exported from a shell profile, will no longer
   reach a pane — the one real regression, accepted because it buys immunity to
   an unbounded list.

3. **Dropping the font fallback stack.** `DEFAULT_FONT_FAMILY` in
   `TerminalPane.tsx` listed Nerd Font variants first, and it existed precisely
   for glyph coverage. Falling back to `NSFont.monospacedSystemFont` instead
   rendered Powerlevel10k's private-use-area icons as replacement boxes.
   `resolveFont` restores the original preference order.

Both were invisible to the headless checks and to `swift build` — the lesson is
that a "port of X" comment is worth little unless the *reason* X looked odd is
carried across with it.

## The default font is bundled

`Resources/Fonts/` ships **JetBrainsMonoNL Nerd Font Mono** (4 faces, ~9 MB),
registered at launch through `ATSApplicationFontsPath` — no system install, and
registration is scoped to the app. It is the first entry in `resolveFont`'s
fallback list because it is the only one guaranteed to resolve; everything after
it is a courtesy to whatever the user already installed.

The point is machines that are not this one. The fallback stack only worked here
by luck: this Mac has exactly one Nerd Font (MesloLGS NF, installed for
Powerlevel10k) out of 8 monospaced families. A fresh machine falls through to
Menlo, and measured against the glyphs this shell's prompt actually emits, Menlo
is missing 6 of 10 — the powerline arrows, `U+F179`, `U+F015`, folder and git
branch. That is the box-glyph bug returning for every other user.

Two build choices worth keeping:

- **NL (no ligatures).** SwiftTerm shapes with
  `CTLineCreateWithAttributedString` and CoreText applies ligatures by default,
  so they *would* render. In a cell-addressed grid a ligature spanning two cells
  risks column and selection misalignment, so the no-ligature build removes the
  question. Swapping in the ligature build is a four-file change.
- **Mono.** Nerd Fonts ship icons double-width by default, which overflow a
  terminal cell and shift everything after them. `Mono` forces single width.

Licensing is in `Resources/Fonts/NOTICE.md`: JetBrains Mono is OFL 1.1, but the
patched-in icon glyphs aggregate several upstream sets under mixed terms, some
requiring attribution (Font Awesome is CC BY 4.0). Read that before shipping to
anyone outside this repo.

## Cloud providers

All six providers are wired: `apple`, `anthropic`, `openai`, `gemini`,
`perplexity`, `ollama`. Anthropic and Gemini were the last two, and are
rewrites rather than ports — the Electron versions asked for a text format in
prose and used 2024-era model defaults.

Each carries the *same* schema to a different mechanism, which is why
`AISchemas` defines them once: Ollama's `format`, OpenAI's `response_format`,
Anthropic's `output_config.format`, Gemini's `generationConfig.responseSchema`.
Two provider-specific traps:

- **Anthropic**: `output_config.format` is the current mechanism. Forcing a tool
  call with `tool_choice: {type: "tool"}` returns a 400 on current models, an
  assistant prefill of `{` is also rejected, and the top-level `output_format`
  parameter is deprecated — all three are patterns a model trained on older docs
  will reach for. `thinking` is omitted rather than disabled, because explicitly
  disabling it is a documented cause of tool calls and reasoning tags leaking
  into visible text. Responses are searched for the first `text` block rather
  than indexed at `content[0]`, which is a `thinking` block when thinking is on.
- **Gemini**: `responseSchema` is a JSON Schema *subset* that rejects
  `additionalProperties`, which the shared schemas must include for the other
  providers — so it is stripped recursively on the way out. The key goes in the
  `x-goog-api-key` header, not the URL, so it stays out of logs. A 200 can carry
  no text at all when `finishReason` is `SAFETY` or `MAX_TOKENS`; that is
  Gemini's refusal shape and produces a clear error rather than an empty string.

### Verifying providers nobody has keys for

`Scripts/mock-ai-api.py` plus `--check-cloud` is the only coverage these have. A
wrong field name fails identically to a wrong key against the real API, so the
parts that are actually ours — auth header, schema placement, response decoding
— are checked against a local mock instead.

The mock's canned replies are shaped to catch two specific mistakes: the
Anthropic reply leads with a `thinking` block, so indexing `content[0]` reads
the wrong thing; the Gemini reply splits its JSON across two `parts`, so taking
`parts[0]` yields truncated JSON. Both were caught this way rather than in
production.

Still unverified: every cloud provider against its real API, and the model IDs
in their defaults.

## Theme contrast is enforced, not eyeballed

`TermAInal --check-contrast` prints WCAG contrast ratios for the sidebar's
derived colours across every built-in theme and exits non-zero if any falls
below its floor (body and dim text 4.5:1, accent 3:1, and a 0.029 luminance step
between a card and the sidebar behind it).

It exists because deriving colours by fixed blend fractions cannot work across
themes, and shipped visibly broken. A proportional shift means something
different on `#002b36` than on `#282a36`, and Solarized Dark's foreground
(`#839496`) is deliberately low-contrast before anything is done to it:

| theme | dim text before | after |
|---|---|---|
| default | 4.91 | 6.17 |
| dracula | 4.18 | 5.15 |
| solarized-dark | **1.93** | 4.72 |
| one-dark | **2.44** | 4.69 |

Card surfaces were 0.012–0.015 luminance from the sidebar behind them, i.e.
invisible; they are now at least 0.030. Solarized Dark's *body* text was also
below the floor at 3.65:1.

The lesson is the same one the environment and font regressions taught: a
derived value needs a guaranteed floor, not a plausible-looking formula. Run
this after touching `Palette` or adding a theme.

## Tabs

`TabController` owns the tab set; **each tab owns a whole `PaneController`**, so
splitting still works inside a tab and none of the pane-tree behaviour had to be
rebuilt. MCP exposes panes across *every* tab, not just the visible one — a
shell in a background tab is still live and an agent may be driving it.

The slide comes out of the layout rather than a bespoke transition: the content
area is one horizontal strip holding every tab's view side by side, each exactly
one viewport wide, and selecting a tab animates the strip's offset by a multiple
of that width. The outgoing tab therefore travels left or right according to
where the incoming one sits in the order, with no direction logic anywhere.
Because the offset is a function of viewport width it is recomputed on resize
rather than stored.

### The split bug

Splits genuinely were broken, and not subtly: `buildView` called
`addArrangedSubview` and **never set a divider position**. `NSSplitView` then
lays children out at whatever frame they already had — and because this app
reuses terminal views across relayouts, those frames were stale, often zero. So
a fresh split came out at arbitrary and sometimes invisible proportions.

`EvenSplitView` distributes evenly the first time it is given a real size.
Positions can only be set once the split itself has a width, hence `layout()`
rather than construction. Measured after the fix: child widths `[599, 599]`,
spread 0.

### One command palette, with a visible way in

The Electron build had a command palette *and* a separate task planner on two
shortcuts. That asked the user to classify their own request before making it,
and the classification was wrong either way: "create a repo and commit" is one
request whether it takes one command or four.

There is now one palette and no mode. It always asks for a plan and renders a
one-step plan as a single command, so the model decides how many commands the
request needs. Measured: "list files sorted by size" comes back as one step and
renders as a single command; "create a git repo and make an initial empty
commit" comes back as three and renders as a numbered list.

The opener is an `NSTitlebarAccessoryViewController` button, deliberately in the
titlebar rather than the tab bar — the tab bar hides itself at one tab, which is
most of the time, so a button there would disappear exactly when someone went
looking for it. `Cmd+Shift+P` still works as an accelerator, and `Cmd+Shift+M`
is gone with the planner.

`AIProvider.suggestCommand` is no longer used by the UI but is kept and still
exercised by `--check-ai`: it is the only coverage of the plain-object guided
generation path, where `plan` uses the array-of-references schema that is the
least certain code in the tree.

### Where a new shell starts

`newPaneDirectory` is `inherit` (default), `home`, or `custom` with
`newPaneCustomDirectory`. Set on the Terminal tab, where the folder field
appears only for the custom mode and has a Choose… panel.

One preference covers **both tabs and splits**: each is "another shell, opened
from here", and having them disagree about the starting directory would be
arbitrary. A custom path that no longer resolves falls back to inheriting rather
than dumping the user at `/`.

Note new tabs already inherited before this, but by spawning in the home
directory and then sending `cd … && clear`. That left the command in shell
history and briefly showed the wrong directory. `PaneController(startingIn:)`
now sets the directory on the node before `rebuild()`, so it reaches
`startProcess(currentDirectory:)` at spawn time — verified by checking
`CommandLog` contains no `cd` for a newly opened tab in any of the four modes.

### Ending a session

Ctrl+D exits the shell, and what that closes depends on what is left:

| state | Ctrl+D closes |
|---|---|
| a split pane | that pane, tab stays |
| a tab with one pane, others open | that tab |
| the only tab | the window, which quits the app |

The last case was broken: `closeTab` refused when one tab remained, so the
pane could not close either and the window sat there hosting a terminal whose
process had already exited. `onLastTabClosed` now reports it and the app closes
the window, matching Terminal.app and iTerm2.

`--check-ctrld` walks all three levels, because the teardown chain runs
pane → tab → window and a break anywhere in it leaves dead UI rather than an
error.

### Titles

Three levels, each showing what suits its width:

- **Window title** — the frontmost tab's fuller form: a whole path with home
  abbreviated to `~`, or whatever a running program named itself. Visible
  despite the hidden-inset titlebar, because the title is how you identify a
  window without switching to it.
- **Tab label** — the compact form, the last path component only. A tab is too
  narrow for a path and the leaf is what distinguishes it.
- Neither shows zsh's default `user@host:path` verbatim. The user and host never
  change, so they spend most of a titlebar saying nothing; `normalisedTitle`
  keeps the path and leaves a program's own title (no `@` before the colon)
  exactly as given.

A program's title only persists while it runs — Powerlevel10k's `precmd` resets
it at every prompt, which is also true in Ghostty.

Note tabs are restored before the window exists, so `refreshSelectedTitle()` is
called after `buildWindow()`; without it the first notification is dropped and
the window keeps its placeholder name.

### Shortcuts changed

Tabs took the conventional bindings, which means the Electron build's
non-standard ones moved:

| | before | now |
|---|---|---|
| New tab | — | `Cmd+T` |
| Close tab | — | `Cmd+Shift+W` |
| Next / previous tab | — | `Cmd+Shift+]` / `Cmd+Shift+[` |
| Select tab 1-9 | — | `Cmd+1`…`Cmd+9` |
| Split right / down | `Cmd+T` / `Cmd+Shift+T` | `Cmd+D` / `Cmd+Shift+D` |
| Split left / up | `Cmd+Alt+T` / `Cmd+Shift+Alt+T` | `Cmd+Alt+D` / `Cmd+Shift+Alt+D` |
| Focus pane 1-9 | `Cmd+1`…`Cmd+9` | `Cmd+Alt+1`…`Cmd+Alt+9` |

`Cmd+W` still closes the active pane, and now closes the tab when it is the last
pane in it.

A session written before tabs held a single `layout` key; it decodes as one tab
containing that layout, verified against a real pre-tabs file.

## Verifying pane reuse

The most fragile invariant in the app is that a relayout re-parents terminals
rather than recreating them — get it wrong and every split silently kills the
running shells. GUI automation cannot reach it (`System Events` keystrokes need
accessibility permission, which the app does not have), so it was checked with a
throwaway `--self-test-panes` branch in `main.swift`:

```swift
let panes = PaneController()
let first = panes.terminals[panes.activePaneId]
panes.splitActivePane(direction: .horizontal)
assert(panes.terminals[panes.activePaneId] === first)   // object identity
assert(first?.process.running == true)                  // shell still alive
```

Object identity plus `process.running` is the whole test. Worth re-adding
whenever `PaneController`'s view construction changes.

## Known constraints

- **Xcode is now required to build.** The `FoundationModelsMacros` plugin ships
  with Xcode rather than the Command Line Tools, and the Apple provider uses
  `@Generable`. `swift build` still works from the CLI, but only with
  `xcode-select -p` pointing at `/Applications/Xcode.app`. The removed
  `DynamicGenerationSchema` construction is in git history if a CLT-only build
  ever has to come back.
- **Swift 5 language mode.** The target pins `swiftLanguageMode(.v5)`; the
  scaffold has not been audited for Swift 6 strict concurrency. `PaneController`
  and `AppDelegate` are main-actor by convention, not by annotation.
- **`swift build` holds a lock.** Only one build at a time; parallel agents
  cannot each compile.
- **Untested at runtime:** every AI path. Apple Intelligence needs to be enabled
  in System Settings, and the cloud providers need a key in the Keychain. The
  code compiles and the availability probe runs, but no inference has been made.

## Implementation plan

**Parity is not the goal.** A straight port of everything in `src/` would spend
weeks rebuilding features that were never the point — the iTerm theme importer
being the clearest example. The plan below reaches *dogfoodability* first (can
this replace the Electron build in daily use?), then moves to the features that
justify a native app at all.

### Phase 1 — Dogfoodable (the gate)

**Phase 1 is complete.** Only image paste lacks a visual confirmation.

In rough dependency order:

1. **Settings UI** — done, `Settings/SettingsWindowController.swift`. Only
   working providers are listed; Anthropic and Gemini are omitted rather than
   offered as dead ends. This unblocked testing the AI paths at all. Needs provider picker, Apple
   on-device/PCC switch, the Apple Intelligence availability panel (port the
   diagnostics from the Electron `Settings.tsx`), key field writing to
   `KeychainStore`, font, theme, and the MCP section. An `NSTabViewController`
   with three tabs mirrors the existing layout. **Largest single item in Phase 1.**

   Includes **Ollama model discovery**: port the `get-ollama-models` handler
   (`GET {baseUrl}/api/tags`) so the model field becomes a populated dropdown
   when Ollama is the provider, as it was in `Settings.tsx`. The inference path
   itself is already done.
2. **Verify the AI paths end to end.** Done for Ollama; blocked for Apple
   (not enabled in System Settings) and cloud (no key). See "Not verified"
   above — `AppleSchemas.plan`'s array-of-references schema is still the least
   certain code in the tree.
3. **Apply font settings** — done. `TerminalPaneView.applyAppearance` sets the
   font, falling back to the system monospaced font when the family is blank or
   unresolvable.
4. **Themes, minus the importer** — done. Four built-ins ported to
   `TerminalThemes` and applied via `installColors` plus
   foreground/background/caret/selection. `parseItermTheme` is **dropped by
   decision**; `customTheme`/`customThemeName` stay out of `AppSettings`.
5. **Session restore** — done. `SessionStore` persists the layout with each
   pane's directory inline, rather than the layout plus a parallel `cwds` array
   the Electron version used, which removes an index-alignment bug class.
   Directories are resolved live at capture time, so the separate `before-quit`
   cwd refresh is unnecessary.
6. **Image paste** — implemented. SwiftTerm renders both Sixel and the iTerm2
   OSC 1337 `File=` protocol natively, so Cmd+V converts a clipboard image to
   PNG and feeds the escape sequence to the emulator, falling back to a text
   paste. **Needs a visual check** — it cannot be verified headlessly.

Exit criterion: you have used it for a full day without reaching for the
Electron build.

### Phase 3 progress — the assistant sidebar

Built ahead of Phase 2, because the request for "insights after execution, not
in flight" *is* the OSC 133 work: an insight needs a command boundary with an
exit status, which a flat output buffer cannot provide.

- **`Terminal/CommandLog.swift`** — parses OSC 133 semantic prompt marks
  (`A` prompt, `B` command start, `C` execution, `D;<exit>` finish) plus
  `1337;CurrentDir=`, turning the PTY stream into `CommandRecord`s carrying
  command, cwd, output, exit code and duration. Chunk-boundary safe via a
  per-pane carry buffer; capped at 200 records and 256 KB of output each.
  The same output tap now feeds two consumers: `OutputBuffer` for flat MCP
  reads, `CommandLog` for structure.
- **`Assistant/AssistantSidebarView.swift`** — collapsible right sidebar with a
  transcript of insights and Q&A, themed from the terminal palette.
- **`Assistant/AssistantController.swift`** — subscribes to finished commands,
  decides what deserves comment, routes questions with the last three commands
  as context.
- Toggle with `Cmd+Shift+A`. Auto-collapses below a 900pt window width and
  comes back when there is room, unless the user closed it themselves.
- `assistantInsights` is `off` / `failures` / `all`, defaulting to `failures`:
  commentary after every successful command is mostly noise and a standing cost.

Verified against the real shell — commands, exit codes, stderr and durations all
captured correctly, and a failing `ls` produces a correct diagnosis from both
qwen3:4b and Apple's on-device model.

Three things this surfaced:

1. **`PROMPT_SP` leaks into captured output.** zsh writes `%` plus padding
   before drawing the next prompt, and on this machine that lands *before* the
   `D` mark, so it fell inside the command's own output. Harmless on screen,
   pure wasted context once records are fed to a model. Trimmed at record close.
2. **The free-form path was the one place without schema protection, and it
   broke immediately.** Asked for a two-sentence insight, qwen3:4b returned
   eleven paragraphs of chain-of-thought. `answer` is now schema-constrained on
   both providers like the other two entry points, plus a `ReplyCleaner` for the
   `<think>` tag variants a schema cannot catch because the tags land inside the
   field.
3. **Small models over-use an escape hatch.** The insight prompt offered
   "reply NOTHING if there is nothing to say"; qwen3:4b used it on `ls` against
   a path that does not exist — the exact case the feature exists for. The
   opt-out is now offered only for commands that succeeded.

Apple's on-device model performs *well* here, unlike at command generation.
Explanation and summarisation are what a 3B model is suited to, which is the
concrete argument for tiering by task rather than picking one provider — still
to build.

### Two AI profiles

`AppSettings` holds **two** `AIProfile` values rather than one flat provider
configuration:

| profile | used by | what matters |
|---|---|---|
| `commandProfile` | command palette (Cmd+Shift+P) | correct shell syntax |
| `insightProfile` | assistant sidebar insights and questions | explanation quality, low cost |

The split is measured, not speculative. On the same failing `ls`, Apple's
on-device 3B gave a correct diagnosis; on command generation the same model
produced `ls -l | sort -rn | tail -n 1`, which sorts by link count and returns
the *smallest* file. `qwen3:4b` was the reverse trade — accurate syntax, ~2.6 GB
resident. Neither is the right answer for both jobs, so the app stops pretending
one provider serves both.

Migration: a settings file written before the split carries flat `provider` /
`model` / `baseUrl` / `appleModel` keys, and **both** profiles inherit them.
An upgrade therefore changes nothing until the user chooses to differ —
silently moving one role to a different model would be worse than leaving them
identical.

API keys moved from a single keychain entry to one per provider
(`apiKey.<provider>`), read through `SettingsStore.apiKey(for:)`. A key belongs
to a service, not a role: two profiles both pointing at OpenAI share one key
rather than needing it entered twice and drifting. The old unqualified entry is
still read as a fallback so an upgrade does not appear to lose it.

`--check-ai` exercises both roles and reports which failed, since a working
command profile says nothing about the assistant's.

The settings UI builds one reusable `AIProfileEditor` and instantiates it twice
behind a segmented control. That extraction matters for more than tidiness: the
same bug had already appeared twice in this file — a control whose stored value
matches no item stays on index 0, and Save then persists that as the user's
choice. It cost an automatic font (silently replaced with Andale Mono) and would
have rewritten an `anthropic` config to Apple. Duplicating the control set would
have invited a third instance. The editor is now immune by construction: every
popup item carries its key in `representedObject`, selection is by key, an
unrecognised stored value is *appended* as `"<name> (not ported)"` and selected,
and read-back goes through `selectedItem?.representedObject` rather than an
index into a parallel array. Applying that uniformly also caught a third case
nobody had noticed — the Apple-model popup did `index == 1 ? "pcc" :
"on-device"`, so any other stored value was silently rewritten.

### Phase 2 — Close the honest gaps

Small, mechanical, and each one is a thing an existing user would notice missing.

- **MCP restart on settings change.** `MCPServer` is immutable per port;
  `applyMcpSettings`' behaviour needs `stop()` + a fresh instance when the port
  or enabled flag changes.
- **Pane labels.** `PaneNode.label` is plumbed through to MCP but nothing sets
  it. Needs a rename affordance (double-click a pane header, or a menu item).
- **Hidden panes.** Re-introduce the explicit "not visible to MCP" concept, or
  decide the `panesProvider` omission is enough and delete the idea.
- ~~**Anthropic and Gemini providers**~~ — **done.** All six are wired.
- **Follow-up refinement** in the AI palette.

### Phase 3 — The part that justifies the rewrite

This is the agent-workbench direction, and it is the reason to be native rather
than a nicer Electron app. Everything here is new capability, not a port.

7. **Parse OSC 133 instead of stripping it.** *This is the keystone, and it is
   cheaper than expected:* while testing the MCP buffer I found the shell here
   is **already emitting OSC 133 semantic marks** (`133;A` prompt start,
   `133;B` command start, `133;D;<exit>` command end with status) plus
   iTerm2-style `1337;CurrentDir=`. `ANSIStripper` currently throws all of it
   away. Parsing it instead turns the flat byte buffer into a list of command
   records — command text, cwd, exit code, duration, output — with no shell
   configuration required from the user.

   Everything below depends on this, and so does most of the product argument:
   - **Blocks UI** — collapsible per-command output, re-run, copy, jump to
     failures. Falls out of the command records almost for free.
   - **Structured MCP reads** — `get_terminal_output` stops returning a wall of
     bytes and starts returning "the last 5 commands and their exit codes",
     which is dramatically more useful to an agent and much cheaper in tokens.
   - **"Explain this failure"** — a non-zero exit becomes an affordance, and
     the on-device model is well suited to summarising the output.

8. **Agent-aware pane status.** Detect whether a pane is running an agent CLI
   and surface idle / working / awaiting-input / done, with notification on
   state change. Depends on (7) for command boundaries. This is the unserved
   need — nothing else on the market knows what an agent is.
9. **Worktree orchestration.** "Start a task" = create the git worktree, spawn
   the pane, launch the agent, label it, tear it all down as a unit.
10. **MCP policy + audit layer.** Allow/deny/ask rules over
    `send_input_to_terminal`, plus an append-only log of what ran and on whose
    behalf. The current server executes anything a local client asks for. This
    is the piece that makes the MCP server safe to leave running, and the one a
    company would pay for.

### Phase 4 — Shippable

- **Swift 6 strict concurrency.** Drop `swiftLanguageMode(.v5)` and annotate
  properly. `PaneController` and `AppDelegate` are main-actor by convention
  today, not by declaration; `OutputBuffer` and `MCPServer` already use serial
  queues.
- **Signing, notarization, DMG.** Replaces `electron-builder`. `make-app.sh`
  currently ad-hoc signs. Needs a Developer ID, a hardened-runtime entitlements
  file (but *not* the sandbox — the child shell needs full access), and
  `notarytool`.
- **Updates.** Sparkle, or whatever replaces the current GitHub-release flow.
- ~~**Retire `src/`**~~ — **done.** Electron is deleted; `electron-final` tags
  its last state. The Windows and Linux packaging targets had already been
  removed, so it had no remaining role.

### Decisions taken

1. **Xcode: install it.** Once present, `AppleSchemas`' runtime
   `DynamicGenerationSchema` construction collapses into two `@Generable`
   structs, and Instruments becomes available for the latency work in Phase 3.
   The SPM layout stays as-is — Xcode opens `Package.swift` directly, so no
   `.xcodeproj` is needed and the CLI build keeps working.
2. **Windows and Linux: dropped.** The `win`, `linux` and `nsis` electron-builder
   targets and the `dist:win`/`dist:linux`/`dist:all` scripts are removed;
   `dist` now builds macOS only. Native Swift is therefore the right target, and
   the Tauri alternative is off the table.
3. **Providers: Ollama stays.** Anthropic and Gemini remain unported and
   undecided.
4. **iTerm theme import: dropped.** Built-in themes only.

### Local model guidance (Ollama)

Measured on this machine, same two prompts via `--check-ai`:

| model | resident | result |
|---|---|---|
| `qwen2.5-coder:14b` | ~9 GB | `ls -lhS` — correct, but heavy enough to slow the system |
| `qwen3:4b` | ~2.6 GB | `ls -lhS` — correct, 3.7s warm. **Best balance** |
| `erwan2/DeepSeek-R1-Distill-Qwen-1.5B` | ~1 GB | `ls -d`, `git revlist -a`, a bare `/my-repo` — unusable |

Two things this surfaced, both now fixed in `OpenAICompatibleProvider`:

- **URLSession's 60s default was too short.** A cold local model can spend most
  of a minute loading before emitting a token; qwen3:4b timed out at 61.5s cold
  and answered in 3.7s warm. Ollama now gets 300s, cloud providers 90s.
- **Reasoning models are a poor fit** for command generation — they spend the
  budget thinking. `think: false` is sent to Ollama (harmless on models without
  a thinking mode) but does not reliably suppress it: qwen3 still emits its
  trace into `content`. Prefer a non-reasoning, coder-tuned model.

The distilled DeepSeek is a reasoning model *and* small enough to be wrong
about flags, which is the worst combination for this task. If RAM is the
constraint, `qwen3:4b` is the pick; `qwen2.5-coder:7b` (~4.7 GB, not installed)
would be the coder-tuned middle ground.

Better still, once Apple Intelligence is enabled: the on-device model costs no
resident RAM of its own and needs no model load, which is precisely the problem
a 14b local model creates.

### Suggested order

Do 1 and 2 next, together — they are one unit of work, since the settings UI
exists in order to make the AI testable. Then 3 and 4 in an afternoon. Then
decide whether to finish Phase 1 (5, 6) or jump to 7, because 7 is where this
stops being a port and starts being the thing worth building.
