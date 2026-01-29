# Project Context: Term-AI-nal

## Project Overview
**Term-AI-nal** is an AI-powered terminal emulator for macOS. It integrates standard terminal functionality with an agentic AI assistant that translates natural language instructions into executable shell commands. The application is designed to be safe, context-aware, and highly configurable.

## Technology Stack
- **Runtime:** Electron (Main Process + Renderer)
- **Frontend:** React + TypeScript + Vite
- **Terminal Engine:** xterm.js
- **Shell Integration:** node-pty (runs `zsh` as a login shell)
- **Styling:** CSS-in-JS (React inline styles)
- **Icons:** lucide-react
- **Build System:** electron-builder

## Key Features & Requirements

### 1. Terminal Emulation
- **Native Experience:** Must run a real `zsh` session using `node-pty`.
- **Login Shell:** Must spawn with `--login` to ensure user environment variables (PATH, aliases) are loaded correctly.
- **Visuals:** Dark theme, borderless/hiddenInset window style for macOS.

### 2. AI Integration
- **Command Palette:** Triggered via `Cmd+Shift+P`.
- **Providers:** Support for OpenAI, Anthropic (Claude), Google (Gemini), Perplexity, and Ollama (Local).
- **Configuration:** Dedicated Settings UI to manage API keys and Model selection.
- **Ollama Support:** Auto-detection of installed local models and default URL (`http://localhost:11434`).

### 3. Agentic Workflow
- **Safety First:** AI NEVER executes commands automatically. All commands must be reviewed by the user.
- **Response Format:** AI must return a strict JSON-like format containing:
    - `COMMAND`: The raw executable code.
    - `EXPLANATION`: A concise (<10 words) description of what the command does.
- **Context Awareness:** System prompt must inject the current OS, Release, Architecture, and Shell to ensure valid command generation.
- **Refinement:** Users can refine a generated command using the "Follow-up" input box if the initial suggestion is incorrect.

### 4. User Interface
- **Split Panes:** Support for multiple side-by-side terminal panes (`Cmd+D` to split).
- **Active Pane:** AI commands are targeted to the currently focused/active pane.
- **Review UI:** A dedicated overlay for reviewing AI suggestions before execution, displaying the explanation separately from the code.

## Architecture

### Main Process (`src/main/main.ts`)
- Manages window creation.
- Handles `node-pty` sessions (creation, resizing, input/output).
- Manages a `Map` of terminal IDs to PTY processes.
- centralized **AI Service** that handles API calls to different providers via `fetch`.
- Persists user settings (keys, providers) to disk (`userData/settings.json`).

### Renderer Process (`src/renderer/`)
- **App.tsx:** Main layout manager. Handles the list of terminal panes, AI overlay, and global shortcuts.
- **TerminalPane.tsx:** Wrapper around `xterm.js` and `xterm-addon-fit`. Manages individual terminal instance rendering.
- **Settings.tsx:** Form for configuring AI providers.

## Build & Distribution
- **Scripts:**
    - `npm run dev:electron`: concurrent Vite + Electron dev server.
    - `npm run dist`: Production build and packaging for macOS (`.dmg`).
- **Artifacts:** Builds are output to the `release/` directory.

## Future Considerations
- Windows/Linux support (currently optimized for macOS).
- Tabbed interface (in addition to split panes).
- Theme customization.
