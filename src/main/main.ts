import { app, BrowserWindow, ipcMain, shell as electronShell, safeStorage } from 'electron';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
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
  theme: 'default', // 'default', 'dracula', 'solarized-dark', 'one-dark', 'custom'
  customTheme: null, // For imported iTerm themes
  customThemeName: '', // Name of imported theme
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
  });

  // Settings & AI
  ipcMain.handle('get-settings', () => loadSettings());
  ipcMain.handle('save-settings', (event, settings) => saveSettings(settings));
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
  ipcMain.handle('open-external', async (event, url) => {
    try {
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
  createWindow();
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