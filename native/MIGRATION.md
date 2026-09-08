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
5. **JSON-RPC id fidelity.** A bug found during the port: `JSONSerialization`
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

## Known constraints

- **`@Generable` needs Xcode.** The `FoundationModelsMacros` plugin ships with
  Xcode, not Command Line Tools, so the macro cannot expand here. The schemas
  are built at runtime with `DynamicGenerationSchema` instead — same guarantee,
  more verbose. If you install Xcode, `AppleSchemas` could collapse into two
  `@Generable` structs.
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

Nothing else matters until you can use this instead of the Electron build. In
rough dependency order:

1. **Settings UI** — `Settings/SettingsWindow.swift`. Highest value, because it
   unblocks *testing the AI paths at all*: with no way to pick a provider or
   store a key, `AIService` is unreachable. Needs provider picker, Apple
   on-device/PCC switch, the Apple Intelligence availability panel (port the
   diagnostics from the Electron `Settings.tsx`), key field writing to
   `KeychainStore`, font, theme, and the MCP section. An `NSTabViewController`
   with three tabs mirrors the existing layout. **Largest single item in Phase 1.**
2. **Verify the AI paths end to end.** Currently unproven. Order: Apple
   on-device (no key needed) → OpenAI-compatible against a local endpoint →
   a real cloud key. Confirm `DynamicGenerationSchema` actually round-trips —
   the array-of-references schema in `AppleSchemas.plan` is the least certain
   code in the tree.
3. **Apply font settings** — `fontSize`/`fontFamily` are parsed and ignored.
   `TerminalView` takes an `NSFont`; wire it through `TerminalPaneView.init` and
   re-apply on settings change. Small, but it is the first thing you will notice.
4. **Themes, minus the importer** — port the four palettes from `themes.ts` into
   a Swift `TerminalTheme` struct and apply via SwiftTerm's colour API. **Skip
   `parseItermTheme`**; it is a lot of plist handling for a feature used once.
   Revisit only if you miss it.
5. **Session restore** — `session.json`, layout + cwd persistence, and the
   `before-quit` cwd refresh. `PaneNode` is already tree-shaped and
   `ProcessCwd.lookup` already works, so this is mostly `Codable` on the tree
   plus an `applicationWillTerminate` hook.
6. **Image paste** — `pasteImageToTerminal` has no equivalent. SwiftTerm needs
   checking for Sixel/iTerm2 inline-image support before committing to this.

Exit criterion: you have used it for a full day without reaching for the
Electron build.

### Phase 2 — Close the honest gaps

Small, mechanical, and each one is a thing an existing user would notice missing.

- **MCP restart on settings change.** `MCPServer` is immutable per port;
  `applyMcpSettings`' behaviour needs `stop()` + a fresh instance when the port
  or enabled flag changes.
- **Pane labels.** `PaneNode.label` is plumbed through to MCP but nothing sets
  it. Needs a rename affordance (double-click a pane header, or a menu item).
- **Hidden panes.** Re-introduce the explicit "not visible to MCP" concept, or
  decide the `panesProvider` omission is enough and delete the idea.
- **Anthropic and Gemini providers** — or **decide to drop them.** Worth asking
  whether five providers was ever right, now that the Apple path is free and
  keyless and `baseUrl` covers anything OpenAI-shaped.
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
- **Retire `src/`** once Phase 1 holds, or keep Electron as the
  Windows/Linux target and accept the divergence.

### Decisions needed from you

These change the plan rather than just its order:

1. **Install Xcode?** It buys `@Generable` (collapsing `AppleSchemas` to two
   annotated structs), Instruments, and the visual debugger. Costs ~10GB and
   makes the build depend on it. Currently everything works without it.
2. **Keep Windows/Linux?** Going native forecloses them. If they were real
   ambitions, Phase 3 belongs in Tauri instead; if aspirational, say so and
   delete the `dist:win`/`dist:linux` scripts.
3. **Five AI providers, or two?** See Phase 2.
4. **Themes: port or drop?** Phase 1 assumes the four built-ins and no importer.

### Suggested order

Do 1 and 2 next, together — they are one unit of work, since the settings UI
exists in order to make the AI testable. Then 3 and 4 in an afternoon. Then
decide whether to finish Phase 1 (5, 6) or jump to 7, because 7 is where this
stops being a port and starts being the thing worth building.
