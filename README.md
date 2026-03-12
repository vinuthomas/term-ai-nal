# Term-AI-nal

An AI-powered terminal for macOS built with Electron, React, and xterm.js.

## Features
- **Full Terminal Emulator:** Runs `zsh` natively using `node-pty`.
- **AI Command Palette:** Press `Cmd + Shift + P` to open the AI bar.
- **Agentic Workflows:** Type natural language instructions to generate shell commands.
- **Safety First:** All AI-generated commands require manual review and approval before execution.

## Getting Started

### Prerequisites
- Node.js installed.
- macOS (for `zsh` and Mac-style window decorations).

### Installation
1. Install dependencies:
   ```bash
   npm install
   ```
2. Rebuild native modules (happens automatically via postinstall, but can be run manually):
   ```bash
   npm run postinstall
   ```

### Running the App
To start the application in development mode:
```bash
npm run dev:electron
```
*Note: This will start a Vite dev server for the frontend and launch Electron.*

## How to use the AI
1. Click into the terminal window.
2. Press `Cmd + Shift + P`.
3. Type a request, such as:
   - "create a new git repo"
   - "create a empty django project"
   - "delete all files" (Test the safety check!)
4. Review the generated command and click **Execute** to run it in the terminal.

## MCP Server

Term-AI-nal exposes a built-in **Model Context Protocol (MCP)** server that lets external AI agents and tools interact with your terminal panes — read their output, list open panes, and send input.

The server starts automatically when the app launches and listens at:

```
http://127.0.0.1:57320/mcp
```

### Available Tools

| Tool | Description |
|---|---|
| `list_terminals` | List all open panes with their ID, label, and current working directory |
| `get_terminal_output` | Get the buffered text output of a specific pane by ID |
| `get_active_terminal_output` | Get the buffered text output of the currently focused pane |
| `send_input_to_terminal` | Send text or a command to a specific pane |

### Connecting an MCP Client

#### OpenCode

Add the following to your `~/.config/opencode/opencode.jsonc`:

```json
{
  "mcp": {
    "ai-term": {
      "type": "remote",
      "url": "http://127.0.0.1:57320/mcp",
      "enabled": true
    }
  }
}
```

Then reference it in your prompts:

```
use ai-term to check what's running in my terminal
```

#### Claude Desktop

Add to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ai-term": {
      "url": "http://127.0.0.1:57320/mcp"
    }
  }
}
```

### Testing the MCP Server Manually

Use `curl` to verify the server is running while the app is open:

```bash
# Server info
curl http://127.0.0.1:57320/

# List available tools
curl -s -X POST http://127.0.0.1:57320/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'

# List open terminal panes
curl -s -X POST http://127.0.0.1:57320/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_terminals","arguments":{}}}'

# Get output from a specific pane (last 50 lines)
curl -s -X POST http://127.0.0.1:57320/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_terminal_output","arguments":{"terminal_id":"term-1","lines":50}}}'

# Send a command to a pane
curl -s -X POST http://127.0.0.1:57320/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"send_input_to_terminal","arguments":{"terminal_id":"term-1","text":"echo hello\n"}}}'
```

### Protocol Details

- **Transport:** Streamable HTTP (JSON-RPC 2.0)
- **Endpoint:** `POST http://127.0.0.1:57320/mcp`
- **Protocol version:** `2024-11-05`
- **Output buffer:** Up to 500 KB per pane, ANSI escape codes stripped

---

## Building & Distribution

### Build Commands

Build for your current platform:
```bash
npm run dist
```

Build for specific platforms:
```bash
# macOS (creates .dmg and .zip for both Intel and Apple Silicon)
npm run dist:mac

# Windows (creates .exe installer and portable .exe)
npm run dist:win

# Linux (creates AppImage, .deb, and .rpm)
npm run dist:linux

# All platforms at once
npm run dist:all
```

### Output

Built applications will be in the `release/` directory:

**macOS:**
- `Term-AI-nal-1.0.0-arm64.dmg` - Apple Silicon installer
- `Term-AI-nal-1.0.0-x64.dmg` - Intel installer
- `Term-AI-nal-1.0.0-arm64-mac.zip` - Apple Silicon app bundle
- `Term-AI-nal-1.0.0-x64-mac.zip` - Intel app bundle

> **Note for macOS Users:** If you download a pre-built binary downloaded from the release section and see a warning that the developer cannot be verified:
> 1. Right-click (or Control-click) the app icon and select **Open**.
> 2. Click **Open** in the dialog that follows.
> 3. Alternatively, run `sudo xattr -rd com.apple.quarantine /Applications/term-ai-nal.app` in your terminal.

**Windows:**
- `Term-AI-nal Setup 1.0.0.exe` - NSIS installer (x64 and ia32)
- `Term-AI-nal 1.0.0.exe` - Portable executable (x64)

**Linux:**
- `Term-AI-nal-1.0.0.AppImage` - Universal Linux package
- `term-ai-nal_1.0.0_amd64.deb` - Debian/Ubuntu package
- `term-ai-nal-1.0.0.x86_64.rpm` - RedHat/Fedora package

### Cross-Platform Building

**Building Windows/Linux apps on macOS:**

You can build for Windows and Linux from macOS without issues:
```bash
npm run dist:all
```

**Building macOS apps on Windows/Linux:**

Building macOS apps requires macOS or a macOS virtual machine due to Apple's requirements.

### Code Signing

**macOS:**

To sign your macOS app, you need:
1. An Apple Developer account ($99/year)
2. A Developer ID Application certificate

Set environment variables:
```bash
export CSC_LINK=/path/to/certificate.p12
export CSC_KEY_PASSWORD=your-certificate-password
export APPLE_ID=your@apple-id.com
export APPLE_APP_SPECIFIC_PASSWORD=xxxx-xxxx-xxxx-xxxx
```

**Windows:**

For Windows code signing:
```bash
export CSC_LINK=/path/to/certificate.pfx
export CSC_KEY_PASSWORD=your-certificate-password
```

### Notarization (macOS)

To distribute outside the Mac App Store, your app must be notarized by Apple. This happens automatically if you set the environment variables above and run:

```bash
npm run dist:mac
```

### Requirements for Building

**All platforms need:**
- Node.js 16+ and npm

**Additional requirements:**

- **macOS builds:** Requires macOS (for code signing and notarization)
- **Windows builds:** Works on any platform, but signing requires a Windows code signing certificate
- **Linux builds:** Works on any platform

### Entitlements (macOS)

For native modules like `node-pty`, create `build/entitlements.mac.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
  <key>com.apple.security.cs.allow-jit</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
```

This allows the app to use native Node modules with hardened runtime enabled.
