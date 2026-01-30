import { app, BrowserWindow, ipcMain, shell as electronShell } from 'electron';
import * as path from 'path';
import * as os from 'os';
import * as fs from 'fs';
import * as pty from 'node-pty';
import { execSync } from 'child_process';

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
      return { ...defaultSettings, ...JSON.parse(fs.readFileSync(getSettingsPath(), 'utf-8')) };
    }
  } catch (e) {
    console.error('Failed to load settings', e);
  }
  return defaultSettings;
}

function saveSettings(settings: any) {
  try {
    fs.writeFileSync(getSettingsPath(), JSON.stringify(settings, null, 2));
    return true;
  } catch (e) {
    console.error('Failed to save settings', e);
    return false;
  }
}

// --- iTerm Theme Parser ---
function parseItermTheme(xmlContent: string): any {
  try {
    // Parse iTerm2 .itermcolors XML format
    const colorMap: any = {};

    // Match <key>Color Name</key> followed by <dict> with RGB values
    const keyRegex = /<key>(.*?)<\/key>\s*<dict>([\s\S]*?)<\/dict>/g;
    let match;

    while ((match = keyRegex.exec(xmlContent)) !== null) {
      const colorName = match[1];
      const colorDict = match[2];

      // Extract RGB components (stored as floating point 0-1)
      const redMatch = colorDict.match(/<key>Red Component<\/key>\s*<real>([\d.]+)<\/real>/);
      const greenMatch = colorDict.match(/<key>Green Component<\/key>\s*<real>([\d.]+)<\/real>/);
      const blueMatch = colorDict.match(/<key>Blue Component<\/key>\s*<real>([\d.]+)<\/real>/);

      if (redMatch && greenMatch && blueMatch) {
        const r = Math.round(parseFloat(redMatch[1]) * 255);
        const g = Math.round(parseFloat(greenMatch[1]) * 255);
        const b = Math.round(parseFloat(blueMatch[1]) * 255);
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
    return `echo "Error: ${error.message}"`;
  }
  
  return `echo "Provider not supported"`;
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
      const output = execSync(`lsof -a -d cwd -p ${pid} -Fn`, { encoding: 'utf8' });
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