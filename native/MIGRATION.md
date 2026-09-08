# Electron → native Swift migration

Status of the `swift-migration` branch. The Electron app in `src/` is untouched
and still the shipping build; everything native lives under `native/`.

## Build

```bash
cd native
./Scripts/make-app.sh          # debug build + .app bundle
./Scripts/make-app.sh release  # release build
open build/TermAInal.app
# or, to see stdout/NSLog:
./build/TermAInal.app/Contents/MacOS/TermAInal
```

There is no `.xcodeproj`. This builds with **Command Line Tools only** — the
package is plain SPM, and `Scripts/make-app.sh` hand-assembles the `.app` with
an `Info.plist` because SPM emits a bare executable and AppKit needs a real
bundle for its menu bar, window activation and Keychain identity.
`swift build` alone is enough to typecheck. Opening `native/Package.swift` in
Xcode also works if you install it.

The app is deliberately **not sandboxed** — SwiftTerm's child shell needs full
filesystem access.

`make-app.sh` also generates the app icon, because nothing else does it now:
electron-builder handled that for the Electron target, and the hand-assembled
bundle initially had no `CFBundleIconFile` at all, so the Dock showed the
generic placeholder. It builds a full iconset from `build/icon.png` with `sips`
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
- **Anthropic and Gemini providers.** `AIService.provider(for:)` returns nil for
  both; the other four work.
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
2. **Dropping the font fallback stack.** `DEFAULT_FONT_FAMILY` in
   `TerminalPane.tsx` listed Nerd Font variants first, and it existed precisely
   for glyph coverage. Falling back to `NSFont.monospacedSystemFont` instead
   rendered Powerlevel10k's private-use-area icons as replacement boxes.
   `resolveFont` restores the original preference order.

Both were invisible to the headless checks and to `swift build` — the lesson is
that a "port of X" comment is worth little unless the *reason* X looked odd is
carried across with it.

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
| `commandProfile` | palette (Cmd+Shift+P), task planner (Cmd+Shift+M) | correct shell syntax |
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
- **Anthropic and Gemini providers** — the only two unported, and still an open
  call. Apple, OpenAI, Perplexity and Ollama all work. Ollama is explicitly
  staying.
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
- **Retire `src/`** once Phase 1 holds. There is no cross-platform reason to
  keep it: the Windows and Linux packaging targets have been removed from
  `package.json`, so Electron has no remaining role once the native app is
  dogfoodable.

### Decisions taken

1. **Xcode: install it.** Once present, `AppleSchemas`' runtime
   `DynamicGenerationSchema` construction collapses into two `@Generable`
   structs, and Instruments becomes available for the latency work in Phase 3.
   The SPM layout stays as-is — Xcode opens `native/Package.swift` directly, so
   no `.xcodeproj` is needed and the CLI build keeps working.
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
