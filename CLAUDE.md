# CLAUDE.md - Term-AI-nal

## Project Overview

Term-AI-nal is an AI-powered terminal emulator for macOS built with Electron, React, TypeScript, and xterm.js. It integrates a real `zsh` session (via `node-pty`) with an agentic AI assistant that translates natural language into executable shell commands. Commands are never auto-executed — users always review before running.

## Tech Stack

- **Runtime:** Electron (Main + Renderer processes)
- **Frontend:** React 19 + TypeScript + Vite 7
- **Terminal:** xterm.js (`@xterm/xterm` v6) + `@xterm/addon-fit`
- **Shell:** `node-pty` (spawns `zsh --login`)
- **Styling:** CSS-in-JS (React inline styles)
- **Icons:** lucide-react
- **Build/Package:** electron-builder
- **Resizable layout:** react-resizable-panels

## Project Structure

```
src/
├── main/
│   ├── main.ts          # Electron main process: window, PTY management, AI service, settings persistence
│   └── preload.ts       # Preload script for IPC bridge
└── renderer/
    ├── index.html       # HTML entry point
    ├── index.tsx        # React entry point
    ├── App.tsx          # Main layout: pane management, AI overlay, global shortcuts
    ├── TerminalPane.tsx # xterm.js wrapper, per-pane terminal rendering
    ├── Settings.tsx     # AI provider configuration UI
    ├── Help.tsx         # Help/documentation UI
    ├── ResizablePanels.ts # Resizable split pane logic
    └── themes.ts        # Terminal theme definitions
build/                   # Electron-builder resources (icons, entitlements)
```

## Dev Commands

- `npm run dev:electron` — Start dev server (Vite + Electron concurrently)
- `npm run build:main` — Compile main process TypeScript
- `npm run build:renderer` — Vite production build for renderer
- `npm run start` — Build and launch (production mode)
- `npm run dist` — Package for macOS (.dmg)
- `npm run dist:all` — Package for macOS, Windows, and Linux

## Key Architecture Details

- **Main process** (`src/main/main.ts`): Manages BrowserWindow, PTY sessions (stored in a `Map` by terminal ID), AI API calls to providers, and persists user settings to `userData/settings.json`.
- **Renderer process** (`src/renderer/`): React app handling UI, terminal panes, AI command review overlay, and settings.
- **AI Providers:** OpenAI, Anthropic (Claude), Google (Gemini), Perplexity, Ollama (local). Configured via Settings UI with API keys and model selection.
- **AI Response Format:** Strict JSON with `COMMAND` (executable code) and `EXPLANATION` (concise description).
- **Safety:** AI suggestions are always shown in a review overlay — never auto-executed.

## Key Shortcuts

- `Cmd+Shift+P` — AI command palette
- `Cmd+T` — Split pane right
- `Cmd+Shift+T` — Split pane down

## Build Output

Production builds go to `release/`. The app ID is `com.termainal.app`.
