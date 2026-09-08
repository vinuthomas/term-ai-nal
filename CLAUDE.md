# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Term-AI-nal is an AI-powered terminal emulator (macOS only) built with Electron, React 19, TypeScript, and xterm.js. It runs a real `zsh --login` session via `node-pty` and layers on an AI assistant that translates natural language into shell commands. **Commands are never auto-executed** — the user always reviews them in an overlay first.

It also exposes a built-in **MCP server** so external AI agents can list panes, read terminal output, stream it live over SSE, and send input.

## Dev Commands

- `npm run dev:electron` — dev mode: Vite dev server (port 3000) + Electron, concurrently. Renderer hot-reloads; **main-process changes require a restart** (`build:main` only runs once at launch).
- `npm run build:main` — compile `src/main/*.ts` to `dist/main/` via bare `tsc` CLI flags (this script does **not** use `tsconfig.json`; `tsconfig.json` covers the renderer/Vite side only).
- `npm run build:renderer` — Vite build to `dist/renderer/`.
- `npm run start` — build both, then `electron .` (production paths).
- `npm run dist` / `dist:mac` — package via electron-builder into `release/`. macOS is the only supported target; the Windows and Linux targets were dropped deliberately, and a native Swift rewrite is underway on the `swift-migration` branch (see `native/MIGRATION.md`).
- `npm run postinstall` — `electron-rebuild`; re-run after changing Electron or `node-pty` versions, otherwise the native PTY module won't load.

There is no test suite, linter, or formatter configured. Verify changes by running the app.

## Architecture

Three-layer Electron split. Everything privileged lives in the main process; the renderer only talks to it through the preload bridge.

### Main process — `src/main/main.ts` (~1200 lines, single file)

Responsibilities, in order of appearance:

1. **Settings** (`loadSettings`/`saveSettings`) — persisted to `userData/settings.json` with mode `0o600`. The `apiKey` field is encrypted with Electron `safeStorage` and stored hex-encoded; decryption failures fall through and leave the value as-is (legacy plaintext). `defaultSettings` is the single source of truth for every setting key, including MCP config and per-feature MCP toggles.
2. **Session persistence** — `userData/session.json` holds the pane layout tree plus per-pane CWDs. Only written when `settings.restoreSession` is on. An `app.on('before-quit')` handler re-reads live CWDs from each PTY and rewrites the session so restore lands in the right directories.
3. **iTerm theme import** — `parseItermTheme` converts `.itermcolors` plist XML (via `fast-xml-parser`) into a `TerminalTheme`.
4. **AI service** — `callAIRaw` is the one provider-dispatch function (OpenAI, Perplexity, Anthropic, Gemini, Ollama), each with its own URL/auth/response shape and a hardcoded default model. Two prompt layers sit on top:
   - `callAI` — single-command mode. System prompt demands the exact plain-text format `COMMAND: …\nEXPLANATION: …` (max 10 words), no markdown, no placeholders like `<path>`.
   - `callAIPlan` — multi-step task planner. Demands a bare JSON array of `{cmd, explanation}`, max 10 steps, and validates with `JSON.parse` before returning.
   Both catch errors and return a *well-formed* response whose command is `echo "AI Error: …"`, so the renderer never has to special-case failures. Error text is sanitized to `[a-zA-Z0-9 _.:-]` before interpolation into that shell string.
5. **PTY management** — `ptyProcesses: Map<string, IPty>` keyed by pane id; `createPty` is idempotent per id. `closingTerminals: Set` distinguishes intentional close from a crash so a spurious `terminal-exit` isn't sent. `getCwd(pid)` shells out per-platform (`lsof` on macOS).
6. **Output buffering** — every PTY chunk is ANSI-stripped (`ANSI_RE`) and appended to an in-memory ring buffer sized by `mcpBufferSizeKB`. On overflow it either spills the oldest bytes to `os.tmpdir()/term-ai-nal-buffer-<id>.txt` (`mcpFileBufferEnabled`) or drops them. `getBufferLines` transparently concatenates spill file + memory. Spill files are cleaned up on terminal close and on quit. This buffer exists solely to serve MCP reads — xterm.js keeps its own scrollback.
7. **MCP server** — a hand-rolled `http.createServer` on `127.0.0.1:<mcpPort>` (default 57320), no SDK:
   - `GET /` or `GET /mcp` → server info
   - `POST /mcp` → JSON-RPC 2.0 (`initialize`, `tools/list`, `tools/call`); `MCP_TOOLS` is the tool manifest and `handleMcpToolCall` the dispatcher, gated by `settings.mcpFeatures`
   - `GET /mcp/stream?terminal_id=…` or `?active=true` → SSE of live output; events are `connected`, `output`, `pane_changed`, `heartbeat` (15 s), `closed`
   Pane metadata the server needs (`activePaneId`, `paneLabels`, `mcpHiddenPanes`) is **pushed from the renderer** via fire-and-forget `mcp-set-*` IPC — the main process never reads React state. `applyMcpSettings` restarts the server when the port changes and stops it when disabled.

### Preload — `src/main/preload.ts`

The complete IPC surface, exposed as `window.electronAPI` under `contextIsolation: true` / `nodeIntegration: false`. Grouped into terminal management, settings/AI, utilities, session, and MCP metadata. `onTerminalData`/`onTerminalExit` return unsubscribe functions — always call them on cleanup or listeners leak across pane churn.

**Adding an IPC call means touching three files:** the `ipcMain` handler in `main.ts`, the bridge method in `preload.ts`, and the `Window.electronAPI` type declaration at the top of `App.tsx`. Skipping the preload step yields a silent `undefined is not a function` at runtime.

### Renderer — `src/renderer/`

- **`App.tsx`** — the whole application shell. Pane layout is a recursive `LayoutNode` tree (`group` with `direction` + `children`, or `pane` with `paneId`/`cwd`/`paneNumber`/`label`), manipulated by the pure helpers at the top of the file (`findNodeByPaneId`, `reassignPaneIds`, `collectPaneIds`, `applyCwdsToLayout`, …). Also owns the global keydown handler, the AI command-review overlay, and the task-planner overlay.
- **`TerminalPane.tsx`** — xterm.js wrapper. Terminal instances live in a **module-level `globalTerminals` Map**, not React state, so a pane survives re-renders and layout-tree reshuffles; its container div is re-parented rather than recreated. Exports imperative helpers (`clearTerminal`, `copyOrInterrupt`, `pasteToTerminal`, `pasteImageToTerminal`, `selectAllTerminal`, `clearScreenTerminal`) that `App.tsx` calls from the keyboard handler.
- **`ResizablePanels.ts`** — thin re-export shim mapping `react-resizable-panels` v4's `Group`/`Separator` back to the `PanelGroup`/`PanelResizeHandle` names used throughout.
- **`themes.ts`** — built-in `TerminalTheme` definitions (`default`, `dracula`, `solarized-dark`, `one-dark`); `custom` comes from an imported iTerm theme in settings.
- **`Settings.tsx`**, **`Help.tsx`** — provider/model/theme/MCP configuration UI and in-app docs.

Styling is inline `React.CSSProperties` objects (see the `styles` object at the bottom of each component) — no CSS files, no Tailwind.

## Keyboard Shortcuts

`Cmd+Shift+P` AI palette · `Cmd+Shift+M` task planner · `Cmd+T` split right · `Cmd+Shift+T` split down · `Cmd+Alt+T` split left · `Cmd+Shift+Alt+T` split up · `Cmd+W` close pane · `Cmd+1`–`Cmd+9` focus pane · `Cmd+K` clear screen + scrollback · `Cmd+L` clear screen · `Cmd+C` copy or SIGINT · `Cmd+V` paste (image first, then text) · `Cmd+A` select all.

All are handled in one `keydown` listener in `App.tsx` and accept `metaKey || ctrlKey`. Shortcuts must not fire while an overlay input is focused — the handler checks `isInputFocused` first.

## Conventions

- Vite `root` is `src/renderer`, `base: './'` (required for `file://` loading in production). Dev loads `http://localhost:3000` and opens DevTools; production loads `dist/renderer/index.html` — gated on `process.env.NODE_ENV === 'development'`.
- Window is `titleBarStyle: 'hiddenInset'`; draggable regions use the `WebkitAppRegion` style property.
- Settings are read fresh from disk inside hot paths (e.g. `getBufferMaxChars` on every buffer append) rather than cached — cheap enough, but keep it in mind before adding expensive work to `loadSettings`.

## Release Process

**Never automatically push commits or create GitHub releases without explicit human approval.** Stop after building the DMG and ask the user to test the app. Only push to git and create a GitHub release after the user has tested and confirmed the build works.
