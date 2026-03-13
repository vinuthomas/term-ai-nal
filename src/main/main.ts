import { app, BrowserWindow, ipcMain, shell as electronShell, safeStorage } from 'electron';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import * as http from 'http';
import * as pty from 'node-pty';
import { execFileSync } from 'child_process';
import { XMLParser } from 'fast-xml-parser';

// --- Settings Management (Simple FS based) ---
const getUserDataPath = () => app.getPath('userData');
const getSettingsPath = () => path.join(getUserDataPath(), 'settings.json');

const defaultSettings = {
  provider: 'openai',
  apiKey: '',
  model: 'gpt-4o',
  baseUrl: '', // For Ollama or custom endpoints
  fontSize: 14,
  fontFamily: '', // Empty = auto-detect Unicode-compatible font stack
  theme: 'default', // 'default', 'dracula', 'solarized-dark', 'one-dark', 'custom'
  customTheme: null, // For imported iTerm themes
  customThemeName: '', // Name of imported theme
  restoreSession: false, // Restore pane layout and working directories on startup
  // MCP settings
  mcpEnabled: true, // Enable/disable MCP server
  mcpPort: 57320, // Port for MCP server
  mcpBufferSizeKB: 500, // Per-terminal in-memory buffer size in KB (overflow spills to temp file)
  mcpFeatures: {
    listTerminals: true,
    getTerminalOutput: true,
    getActiveTerminalOutput: true,
    sendInputToTerminal: true,
  },
};

function loadSettings() {
  try {
    if (fs.existsSync(getSettingsPath())) {
      const data = JSON.parse(fs.readFileSync(getSettingsPath(), 'utf-8'));
      
      // Decrypt API key if it exists
      if (data.apiKey && safeStorage.isEncryptionAvailable()) {
        try {
          // Check if it's hex encoded (our simple way to store buffer)
          const buffer = Buffer.from(data.apiKey, 'hex');
          data.apiKey = safeStorage.decryptString(buffer);
        } catch (e) {
          // If decryption fails (e.g. not encrypted or different machine), keep as is or clear
          // Fallback for legacy plain text: if decrypt fails, it might be plain text
          // but safely checking is hard. Assuming new keys are encrypted.
          console.warn('Failed to decrypt API key, might be invalid or plaintext', e);
        }
      }
      
      return { ...defaultSettings, ...data };
    }
  } catch (e) {
    console.error('Failed to load settings', e);
  }
  return defaultSettings;
}

function saveSettings(settings: any) {
  try {
    const settingsToSave = { ...settings };
    
    // Encrypt API key
    if (settingsToSave.apiKey && safeStorage.isEncryptionAvailable()) {
      const buffer = safeStorage.encryptString(settingsToSave.apiKey);
      settingsToSave.apiKey = buffer.toString('hex');
    }

    fs.writeFileSync(getSettingsPath(), JSON.stringify(settingsToSave, null, 2), { mode: 0o600 });
    return true;
  } catch (e) {
    console.error('Failed to save settings', e);
    return false;
  }
}

// --- Session Persistence ---
const getSessionPath = () => path.join(getUserDataPath(), 'session.json');

function saveSession(sessionData: any) {
  try {
    fs.writeFileSync(getSessionPath(), JSON.stringify(sessionData, null, 2), { mode: 0o600 });
    return true;
  } catch (e) {
    console.error('Failed to save session', e);
    return false;
  }
}

function loadSession() {
  try {
    const sessionPath = getSessionPath();
    if (fs.existsSync(sessionPath)) {
      return JSON.parse(fs.readFileSync(sessionPath, 'utf-8'));
    }
  } catch (e) {
    console.error('Failed to load session', e);
  }
  return null;
}

function clearSession() {
  try {
    const sessionPath = getSessionPath();
    if (fs.existsSync(sessionPath)) {
      fs.unlinkSync(sessionPath);
    }
  } catch (e) {
    console.error('Failed to clear session', e);
  }
}

// --- iTerm Theme Parser ---
function parseItermTheme(xmlContent: string): any {
  try {
    const parser = new XMLParser();
    const result = parser.parse(xmlContent);

    // iTerm2 themes are usually property lists (plist)
    // Structure: <plist><dict><key>Name</key><dict>...</dict>...</dict></plist>
    
    const rootDict = result.plist.dict;
    const keys = rootDict.key; // Array of keys
    const dicts = rootDict.dict; // Array of dicts (values corresponding to keys)
    
    // If single entry, parser might return object instead of array. Ensure array.
    const keyArray = Array.isArray(keys) ? keys : [keys];
    const dictArray = Array.isArray(dicts) ? dicts : [dicts];

    const colorMap: any = {};

    for (let i = 0; i < keyArray.length; i++) {
      const colorName = keyArray[i];
      const colorData = dictArray[i];

      // colorData should contain keys for 'Red Component', 'Green Component', 'Blue Component'
      // and corresponding <real> values.
      // fast-xml-parser converts <key>K</key><real>V</real>... into object structure if simplistic,
      // but plists are alternating key/value.
      // Wait, fast-xml-parser default behavior might not map plist structure directly to clean objects 
      // because plist uses sibling nodes for key/value.
      
      // Actually, standard plist parsing with simple XML parser is tricky because of the 
      // <key>Name</key><value>...</value> sibling structure.
      // Let's implement a more robust logic for the specific structure we have.
      
      // Since we already have the arrays separated (if fast-xml-parser grouped them by tag name),
      // we might need to rely on index matching, which is risky if order isn't preserved.
      
      // BETTER APPROACH for Plist with fast-xml-parser:
      // In a dictionary, keys and values are siblings.
      // <dict>
      //   <key>Ansi 0 Color</key>
      //   <dict>...</dict>
      //   <key>Ansi 1 Color</key>
      //   <dict>...</dict>
      // </dict>
      
      // fast-xml-parser preserves order in 'preserveOrder: true' mode, but we used default.
      // In default mode, it groups by tag name.
      // If the XML is:
      // <dict>
      //    <key>A</key> <dict>valA</dict>
      //    <key>B</key> <dict>valB</dict>
      // </dict>
      // The parsed result is usually { key: ['A', 'B'], dict: [valA, valB] }
      // So index matching should work for this specific schema.

      if (!colorData) continue;

      // Extract RGB. The internal dict structure:
      // <key>Red Component</key><real>0.5</real> ...
      // Parsed: { key: ['Red Component', ...], real: [0.5, ...] }
      
      let r = 0, g = 0, b = 0;
      
      const componentKeys = Array.isArray(colorData.key) ? colorData.key : [colorData.key];
      const componentValues = Array.isArray(colorData.real) ? colorData.real : [colorData.real];

      // Find indices
      const rIndex = componentKeys.indexOf('Red Component');
      const gIndex = componentKeys.indexOf('Green Component');
      const bIndex = componentKeys.indexOf('Blue Component');

      if (rIndex !== -1 && gIndex !== -1 && bIndex !== -1) {
        r = Math.round(parseFloat(componentValues[rIndex]) * 255);
        g = Math.round(parseFloat(componentValues[gIndex]) * 255);
        b = Math.round(parseFloat(componentValues[bIndex]) * 255);
        
        colorMap[colorName] = `#${r.toString(16).padStart(2, '0')}${g.toString(16).padStart(2, '0')}${b.toString(16).padStart(2, '0')}`;
      }
    }

    // Map iTerm color names to xterm.js theme format
    const theme: any = {};

    if (colorMap['Background Color']) theme.background = colorMap['Background Color'];
    if (colorMap['Foreground Color']) theme.foreground = colorMap['Foreground Color'];
    if (colorMap['Cursor Color']) theme.cursor = colorMap['Cursor Color'];
    if (colorMap['Cursor Text Color']) theme.cursorAccent = colorMap['Cursor Text Color'];
    if (colorMap['Selection Color']) theme.selection = colorMap['Selection Color'];

    // ANSI colors (0-15)
    const ansiMap = [
      'black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white',
      'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightMagenta', 'brightCyan', 'brightWhite'
    ];

    for (let i = 0; i < 16; i++) {
      const ansiKey = `Ansi ${i} Color`;
      if (colorMap[ansiKey]) {
        theme[ansiMap[i]] = colorMap[ansiKey];
      }
    }

    return theme;
  } catch (error) {
    console.error('Failed to parse iTerm theme:', error);
    throw new Error('Invalid iTerm theme file format');
  }
}

// --- AI Service ---
async function callAI(prompt: string, settings: any) {
  const shell = os.platform() === 'win32' ? 'powershell.exe' : 'zsh';
  const systemInfo = `OS: ${os.platform()} ${os.release()} (${os.arch()})\nShell: ${shell}`;
  const systemPrompt = `You are an expert terminal assistant running on ${systemInfo}.
Your goal is to convert natural language instructions into a SINGLE executable ${shell} command.

CONTEXT: The user's prompt may include [Current Directory: /path/to/dir] - use this to generate contextually relevant commands with correct relative/absolute paths.

CRITICAL RULES:
1. Return your response in this EXACT format:
   COMMAND: <raw executable command>
   EXPLANATION: <concise explanation, MAX 10 WORDS>

2. DO NOT provide multiple command options.
3. DO NOT use markdown blocks or backticks.
4. The EXPLANATION must be a single, short sentence.
5. NEVER use generic placeholders like <path>, <file>, <ip-address>, <url>, etc.
6. If specific values are needed (paths, IPs, URLs, filenames), ask for them in a follow-up question within the EXPLANATION field instead of providing a generic command.
7. Use the current directory context when generating commands - prefer relative paths when appropriate.
8. Example: If user says "connect to server" and no IP is given, respond with:
   COMMAND: echo "Please specify: What is the server IP address or hostname?"
   EXPLANATION: Need specific server address to connect`;

  const { provider, apiKey, model, baseUrl } = settings;

  try {
    if (provider === 'openai' || provider === 'perplexity') {
      // Perplexity is OpenAI compatible
      const url = provider === 'perplexity' 
        ? 'https://api.perplexity.ai/chat/completions' 
        : 'https://api.openai.com/v1/chat/completions';
      
      const response = await fetch(url, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${apiKey}`
        },
        body: JSON.stringify({
          model: model || (provider === 'perplexity' ? 'llama-3.1-sonar-large-128k-online' : 'gpt-4o'),
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: prompt }
          ]
        })
      });
      const data: any = await response.json();
      if (!response.ok) throw new Error(data.error?.message || 'API Error');
      return data.choices[0].message.content.trim();

    } else if (provider === 'anthropic') {
      const response = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01'
        },
        body: JSON.stringify({
          model: model || 'claude-3-5-sonnet-20240620',
          max_tokens: 1024,
          system: systemPrompt,
          messages: [{ role: 'user', content: prompt }]
        })
      });
      const data: any = await response.json();
      if (!response.ok) throw new Error(data.error?.message || 'API Error');
      return data.content[0].text.trim();

    } else if (provider === 'gemini') {
      const url = `https://generativelanguage.googleapis.com/v1beta/models/${model || 'gemini-1.5-flash'}:generateContent?key=${apiKey}`;
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          contents: [{ parts: [{ text: systemPrompt + "\nUser Request: " + prompt }] }]
        })
      });
      const data: any = await response.json();
      if (!response.ok) throw new Error(data.error?.message || 'API Error');
      return data.candidates[0].content.parts[0].text.trim();

    } else if (provider === 'ollama') {
      const url = `${baseUrl || 'http://localhost:11434'}/api/chat`;
      const response = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: model || 'llama3',
          messages: [
            { role: 'system', content: systemPrompt },
            { role: 'user', content: prompt }
          ],
          stream: false
        })
      });
      const data: any = await response.json();
      if (!response.ok) throw new Error('Ollama Error');
      return data.message.content.trim();
    }
  } catch (error: any) {
    const safeMessage = (error.message || 'Unknown error').replace(/[^a-zA-Z0-9 _.:-]/g, '');
    return `COMMAND: echo "AI Error: ${safeMessage}"\nEXPLANATION: AI service request failed`;
  }

  return `COMMAND: echo "Provider not configured"\nEXPLANATION: Select an AI provider in settings`;
}


// --- Main Window & Pty ---
let mainWindow: BrowserWindow | null = null;
const ptyProcesses = new Map<string, pty.IPty>();
const closingTerminals = new Set<string>(); // Track terminals being intentionally closed
const shell = os.platform() === 'win32' ? 'powershell.exe' : 'zsh';

// --- Terminal Output Buffers ---
// Strip ANSI escape sequences for clean text storage
const ANSI_RE = /\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-Za-z]|\x1b[DEMOST=>]|\x07|\x08|\x0d/g;
const terminalOutputBuffers = new Map<string, string>();
// Spill files: when in-memory buffer is full, oldest content overflows to a per-terminal temp file
const terminalSpillFiles = new Map<string, string>();

function getBufferMaxChars(): number {
  const settings = loadSettings();
  const kb = settings.mcpBufferSizeKB ?? 500;
  return Math.max(1024, kb * 1024); // minimum 1 KB, convert to chars (~1 char ≈ 1 byte for ASCII)
}

function appendToBuffer(id: string, rawData: string) {
  const clean = rawData.replace(ANSI_RE, '');
  if (!clean) return;
  const maxChars = getBufferMaxChars();
  const current = terminalOutputBuffers.get(id) || '';
  const combined = current + clean;

  if (combined.length > maxChars) {
    // Spill the oldest portion to the temp file
    const spillChunk = combined.slice(0, combined.length - maxChars);
    const keepChunk = combined.slice(combined.length - maxChars);

    // Write spill chunk to temp file (append)
    let spillPath = terminalSpillFiles.get(id);
    if (!spillPath) {
      spillPath = path.join(os.tmpdir(), `term-ai-nal-buffer-${id}.txt`);
      terminalSpillFiles.set(id, spillPath);
    }
    try {
      fs.appendFileSync(spillPath, spillChunk, 'utf-8');
    } catch (e) {
      console.error(`[Buffer] Failed to write spill file for terminal ${id}:`, e);
    }
    terminalOutputBuffers.set(id, keepChunk);
  } else {
    terminalOutputBuffers.set(id, combined);
  }
}

function getBufferLines(id: string, maxLines?: number): string {
  const memBuf = terminalOutputBuffers.get(id) || '';
  const spillPath = terminalSpillFiles.get(id);

  let fullBuf: string;
  if (spillPath && fs.existsSync(spillPath)) {
    try {
      const spillContent = fs.readFileSync(spillPath, 'utf-8');
      fullBuf = spillContent + memBuf;
    } catch (e) {
      console.error(`[Buffer] Failed to read spill file for terminal ${id}:`, e);
      fullBuf = memBuf;
    }
  } else {
    fullBuf = memBuf;
  }

  if (!maxLines) return fullBuf;
  const lines = fullBuf.split('\n');
  return lines.slice(-maxLines).join('\n');
}

function cleanupSpillFile(id: string) {
  const spillPath = terminalSpillFiles.get(id);
  if (spillPath) {
    try {
      if (fs.existsSync(spillPath)) fs.unlinkSync(spillPath);
    } catch (e) {
      console.error(`[Buffer] Failed to delete spill file for terminal ${id}:`, e);
    }
    terminalSpillFiles.delete(id);
  }
}

// --- MCP Server State (metadata pushed from renderer) ---
let activePaneId: string = '';
let paneLabels: Record<string, string> = {};

// MCP Server instance (kept so we can close/restart it)
let mcpServer: http.Server | null = null;
let mcpCurrentPort: number = 57320;

function getCwd(pid: number): string {
  try {
    if (os.platform() === 'darwin') {
      // macOS: Use lsof to get the current working directory
      const output = execFileSync('lsof', ['-a', '-d', 'cwd', '-p', String(pid), '-Fn'], { encoding: 'utf8' });
      const match = output.match(/n(.+)/);
      return match ? match[1] : process.env.HOME || '/';
    } else if (os.platform() === 'linux') {
      // Linux: Read from /proc
      const cwdPath = fs.readlinkSync(`/proc/${pid}/cwd`);
      return cwdPath;
    }
  } catch (error) {
    console.error(`Failed to get CWD for PID ${pid}:`, error);
  }
  return process.env.HOME || '/';
}

function createPty(id: string, cwd?: string) {
  // If PTY already exists for this ID, don't recreate it
  if (ptyProcesses.has(id)) {
    console.log(`PTY ${id} already exists, skipping creation`);
    return ptyProcesses.get(id)!;
  }

  const ptyProcess = pty.spawn(shell, ['--login'], {
    name: 'xterm-color',
    cols: 80,
    rows: 30,
    cwd: cwd || process.env.HOME,
    env: process.env,
  });

  ptyProcess.onData((data) => {
    appendToBuffer(id, data);
    mainWindow?.webContents.send('terminal-data', { id, data });
  });

  ptyProcess.onExit(() => {
    // Only send exit event if terminal wasn't intentionally closed
    if (!closingTerminals.has(id)) {
      mainWindow?.webContents.send('terminal-exit', { id });
    }
    ptyProcesses.delete(id);
    closingTerminals.delete(id);
  });

  ptyProcesses.set(id, ptyProcess);
  return ptyProcess;
}

// --- IPC Handlers (registered once at app startup) ---
function setupIpcHandlers() {
  // Terminal Management
  ipcMain.on('terminal-create', (event, { id, cwd }) => {
    createPty(id, cwd);
  });

  ipcMain.handle('terminal-get-cwd', (event, id) => {
    const ptyProcess = ptyProcesses.get(id);
    if (ptyProcess) {
      return getCwd(ptyProcess.pid);
    }
    return process.env.HOME || '/';
  });

  ipcMain.on('terminal-input', (event, { id, data }) => {
    const ptyProcess = ptyProcesses.get(id);
    if (ptyProcess) ptyProcess.write(data);
  });

  ipcMain.on('terminal-resize', (event, { id, cols, rows }) => {
    const ptyProcess = ptyProcesses.get(id);
    // Only resize if we have valid dimensions
    if (ptyProcess && cols > 0 && rows > 0) {
      try {
        ptyProcess.resize(cols, rows);
      } catch (error) {
        console.error(`Failed to resize terminal ${id}:`, error);
      }
    }
  });

  ipcMain.on('terminal-close', (event, id) => {
    const ptyProcess = ptyProcesses.get(id);
    if (ptyProcess) {
      closingTerminals.add(id); // Mark as intentionally closing
      ptyProcess.kill();
      ptyProcesses.delete(id);
    }
    terminalOutputBuffers.delete(id);
    cleanupSpillFile(id);
  });

  // Settings & AI
  ipcMain.handle('get-settings', () => loadSettings());
  ipcMain.handle('save-settings', async (event, settings) => {
    const result = saveSettings(settings);
    // Apply MCP settings changes immediately (enable/disable, port change)
    await applyMcpSettings(settings);
    return result;
  });
  ipcMain.handle('get-mcp-url', () => {
    const settings = loadSettings();
    const port = mcpServer ? mcpCurrentPort : (settings.mcpPort || 57320);
    return `http://127.0.0.1:${port}/mcp`;
  });
  ipcMain.handle('get-ollama-models', async (event, baseUrl) => {
    try {
      const url = `${baseUrl || 'http://localhost:11434'}/api/tags`;
      const response = await fetch(url);
      const data: any = await response.json();
      return data.models.map((m: any) => m.name);
    } catch (e) {
      return [];
    }
  });
  ipcMain.handle('ask-ai', async (event, prompt) => {
    const settings = loadSettings();
    return await callAI(prompt, settings);
  });

  // Utilities
  ipcMain.handle('get-system-memory', () => {
    return {
      totalMB: Math.floor(os.totalmem() / 1024 / 1024),
      freeMB: Math.floor(os.freemem() / 1024 / 1024),
    };
  });

  ipcMain.handle('open-external', async (event, url) => {    try {
      const parsedUrl = new URL(url);
      if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
        console.error('Blocked potentially unsafe URL:', url);
        return false;
      }
      await electronShell.openExternal(url);
      return true;
    } catch (error) {
      console.error('Failed to open external URL:', error);
      return false;
    }
  });

  ipcMain.handle('parse-iterm-theme', async (event, xmlContent) => {
    try {
      return parseItermTheme(xmlContent);
    } catch (error: any) {
      throw error;
    }
  });

  // Session persistence
  ipcMain.handle('save-session', (event, sessionData) => saveSession(sessionData));
  ipcMain.handle('load-session', () => loadSession());
  ipcMain.handle('clear-session', () => { clearSession(); return true; });

  // MCP metadata from renderer
  ipcMain.on('mcp-set-active-pane', (event, id: string) => {
    activePaneId = id;
  });
  ipcMain.on('mcp-set-pane-labels', (event, labels: Record<string, string>) => {
    paneLabels = labels;
  });

  // Get CWDs for all active terminals at once (used during session save)
  ipcMain.handle('get-all-terminal-cwds', () => {
    const cwds: Record<string, string> = {};
    for (const [id, ptyProcess] of ptyProcesses) {
      cwds[id] = getCwd(ptyProcess.pid);
    }
    return cwds;
  });
}

// --- MCP Server ---
// Implements the MCP Streamable HTTP transport (single endpoint, JSON-RPC 2.0)
// Docs: https://spec.modelcontextprotocol.io/specification/basic/transports/

const MCP_TOOLS = [
  {
    name: 'list_terminals',
    description: 'List all open terminal panels with their ID, label, and current working directory.',
    inputSchema: {
      type: 'object',
      properties: {},
      required: [],
    },
  },
  {
    name: 'get_terminal_output',
    description: 'Get the buffered text output of a specific terminal panel.',
    inputSchema: {
      type: 'object',
      properties: {
        terminal_id: {
          type: 'string',
          description: 'The terminal panel ID (from list_terminals)',
        },
        lines: {
          type: 'number',
          description: 'Maximum number of tail lines to return (default: all buffered output)',
        },
      },
      required: ['terminal_id'],
    },
  },
  {
    name: 'get_active_terminal_output',
    description: 'Get the buffered text output of the currently active (focused) terminal panel.',
    inputSchema: {
      type: 'object',
      properties: {
        lines: {
          type: 'number',
          description: 'Maximum number of tail lines to return (default: all buffered output)',
        },
      },
      required: [],
    },
  },
  {
    name: 'send_input_to_terminal',
    description: 'Send a text string (e.g. a command followed by \\n) to a specific terminal panel.',
    inputSchema: {
      type: 'object',
      properties: {
        terminal_id: {
          type: 'string',
          description: 'The terminal panel ID (from list_terminals)',
        },
        text: {
          type: 'string',
          description: 'Text to send to the terminal (append \\n to execute as a command)',
        },
      },
      required: ['terminal_id', 'text'],
    },
  },
];

function buildTerminalList() {
  return Array.from(ptyProcesses.keys()).map(id => {
    const ptyProcess = ptyProcesses.get(id)!;
    let cwd = '';
    try { cwd = getCwd(ptyProcess.pid); } catch {}
    return {
      id,
      label: paneLabels[id] || id,
      cwd,
      is_active: id === activePaneId,
    };
  });
}

function handleMcpToolCall(name: string, args: any): string {
  switch (name) {
    case 'list_terminals': {
      const terminals = buildTerminalList();
      return JSON.stringify(terminals, null, 2);
    }
    case 'get_terminal_output': {
      const { terminal_id, lines } = args;
      if (!terminalOutputBuffers.has(terminal_id) && !ptyProcesses.has(terminal_id)) {
        return `Error: Terminal '${terminal_id}' not found. Use list_terminals to see available terminals.`;
      }
      return getBufferLines(terminal_id, lines ? parseInt(lines, 10) : undefined) || '(no output buffered yet)';
    }
    case 'get_active_terminal_output': {
      const { lines } = args || {};
      if (!activePaneId) return 'Error: No active terminal.';
      return getBufferLines(activePaneId, lines ? parseInt(lines, 10) : undefined) || '(no output buffered yet)';
    }
    case 'send_input_to_terminal': {
      const { terminal_id, text } = args || {};
      if (!terminal_id || typeof terminal_id !== 'string') {
        return `Error: Missing required argument 'terminal_id'.`;
      }
      if (text === undefined || text === null) {
        return `Error: Missing required argument 'text'.`;
      }
      if (typeof text !== 'string') {
        return `Error: Argument 'text' must be a string, got ${typeof text}.`;
      }
      const ptyProcess = ptyProcesses.get(terminal_id);
      if (!ptyProcess) {
        return `Error: Terminal '${terminal_id}' not found. Use list_terminals to see available terminals.`;
      }
      ptyProcess.write(text);
      return `Sent ${text.length} characters to terminal '${terminal_id}'.`;
    }
    default:
      return `Error: Unknown tool '${name}'.`;
  }
}

function startMcpServer(port: number = 57320) {
  const server = http.createServer((req, res) => {
    // CORS for local access
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Accept');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    // GET / or GET /mcp — return server info
    if (req.method === 'GET' && (req.url === '/' || req.url === '/mcp')) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({
        name: 'term-ai-nal',
        version: '1.0.0',
        description: 'MCP server for term-ai-nal terminal emulator. Query terminal panel output.',
        tools: MCP_TOOLS.map(t => t.name),
        endpoint: `http://localhost:${port}/mcp`,
      }));
      return;
    }

    // POST /mcp — JSON-RPC 2.0 endpoint
    if (req.method === 'POST' && req.url === '/mcp') {
      let body = '';
      req.on('data', chunk => { body += chunk; });
      req.on('end', () => {
        let rpcRequest: any;
        try {
          rpcRequest = JSON.parse(body);
        } catch {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } }));
          return;
        }

        const { id, method, params } = rpcRequest;

        const respond = (result: any) => {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ jsonrpc: '2.0', id, result }));
        };

        const respondError = (code: number, message: string) => {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }));
        };

        // Load current settings to check which features are enabled
        const currentSettings = loadSettings();
        const features = currentSettings.mcpFeatures || {};

        switch (method) {
          case 'initialize':
            respond({
              protocolVersion: '2024-11-05',
              capabilities: { tools: {} },
              serverInfo: { name: 'term-ai-nal', version: '1.0.0' },
            });
            break;

          case 'notifications/initialized':
            res.writeHead(204);
            res.end();
            break;

          case 'tools/list': {
            const enabledTools = MCP_TOOLS.filter(t => {
              if (t.name === 'list_terminals') return features.listTerminals !== false;
              if (t.name === 'get_terminal_output') return features.getTerminalOutput !== false;
              if (t.name === 'get_active_terminal_output') return features.getActiveTerminalOutput !== false;
              if (t.name === 'send_input_to_terminal') return features.sendInputToTerminal !== false;
              return true;
            });
            respond({ tools: enabledTools });
            break;
          }

          case 'tools/call': {
            const toolName: string = params?.name;
            const toolArgs: any = params?.arguments || {};
            if (!toolName) {
              respondError(-32602, 'Missing tool name');
              return;
            }

            // Check if tool is enabled
            const featureMap: Record<string, string> = {
              list_terminals: 'listTerminals',
              get_terminal_output: 'getTerminalOutput',
              get_active_terminal_output: 'getActiveTerminalOutput',
              send_input_to_terminal: 'sendInputToTerminal',
            };
            const featureKey = featureMap[toolName];
            if (featureKey && features[featureKey] === false) {
              respondError(-32602, `Tool '${toolName}' is disabled.`);
              return;
            }

            const known = MCP_TOOLS.find(t => t.name === toolName);
            if (!known) {
              respondError(-32602, `Unknown tool: ${toolName}`);
              return;
            }
            const output = handleMcpToolCall(toolName, toolArgs);
            respond({
              content: [{ type: 'text', text: output }],
            });
            break;
          }

          default:
            respondError(-32601, `Method not found: ${method}`);
        }
      });
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Not found' }));
  });

  server.listen(port, '127.0.0.1', () => {
    console.log(`[MCP] Server running at http://127.0.0.1:${port}/mcp`);
    mcpCurrentPort = port;
  });

  server.on('error', (err: any) => {
    if (err.code === 'EADDRINUSE') {
      console.error(`[MCP] Port ${port} already in use. MCP server not started.`);
    } else {
      console.error('[MCP] Server error:', err);
    }
  });

  return server;
}

function stopMcpServer(): Promise<void> {
  return new Promise((resolve) => {
    if (!mcpServer) { resolve(); return; }
    mcpServer.close(() => {
      mcpServer = null;
      resolve();
    });
  });
}

async function applyMcpSettings(settings: any) {
  const enabled = settings.mcpEnabled !== false;
  const port = settings.mcpPort || 57320;

  if (!enabled) {
    await stopMcpServer();
    return;
  }

  // Start if not running, or restart if port changed
  if (!mcpServer || mcpCurrentPort !== port) {
    await stopMcpServer();
    mcpServer = startMcpServer(port);
  }
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1000,
    height: 700,
    titleBarStyle: 'hiddenInset',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    backgroundColor: '#1e1e1e',
  });

  if (process.env.NODE_ENV === 'development') {
    mainWindow.loadURL('http://localhost:3000');
    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, '../renderer/index.html'));
  }

  mainWindow.on('closed', () => {
    mainWindow = null;
    // Kill all ptys
    ptyProcesses.forEach(p => p.kill());
    ptyProcesses.clear();
  });
}

app.whenReady().then(() => {
  setupIpcHandlers();
  const settings = loadSettings();
  if (settings.mcpEnabled !== false) {
    mcpServer = startMcpServer(settings.mcpPort || 57320);
  }
  createWindow();
});

// Before quitting, update the saved session with the latest CWDs
app.on('before-quit', () => {
  // Clean up all spill files
  for (const id of terminalSpillFiles.keys()) {
    cleanupSpillFile(id);
  }

  try {
    const settings = loadSettings();
    if (!settings.restoreSession) return;

    const session = loadSession();
    if (!session || !session.layout) return;

    // Update CWDs with the latest values from active PTYs
    const cwds: string[] = [];
    const collectPaneIdsFromLayout = (node: any): string[] => {
      if (node.type === 'pane' && node.paneId) return [node.paneId];
      if (node.children) return node.children.flatMap(collectPaneIdsFromLayout);
      return [];
    };

    const paneIds = collectPaneIdsFromLayout(session.layout);
    for (const id of paneIds) {
      const ptyProcess = ptyProcesses.get(id);
      if (ptyProcess) {
        cwds.push(getCwd(ptyProcess.pid));
      } else {
        // Fall back to the previously saved CWD
        const index = paneIds.indexOf(id);
        cwds.push(session.cwds?.[index] || process.env.HOME || '/');
      }
    }

    session.cwds = cwds;
    saveSession(session);
  } catch (e) {
    console.error('Failed to update session CWDs on quit:', e);
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (mainWindow === null) {
    createWindow();
  }
});