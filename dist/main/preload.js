"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const electron_1 = require("electron");
electron_1.contextBridge.exposeInMainWorld('electronAPI', {
    // Terminal Management
    createTerminal: (id, cwd) => electron_1.ipcRenderer.send('terminal-create', { id, cwd }),
    getTerminalCwd: (id) => electron_1.ipcRenderer.invoke('terminal-get-cwd', id),
    sendTerminalInput: (id, data) => electron_1.ipcRenderer.send('terminal-input', { id, data }),
    resizeTerminal: (id, cols, rows) => electron_1.ipcRenderer.send('terminal-resize', { id, cols, rows }),
    closeTerminal: (id) => electron_1.ipcRenderer.send('terminal-close', id),
    onTerminalData: (callback) => {
        const listener = (_event, { id, data }) => callback(id, data);
        electron_1.ipcRenderer.on('terminal-data', listener);
        return () => {
            electron_1.ipcRenderer.removeListener('terminal-data', listener);
        };
    },
    onTerminalExit: (callback) => {
        const listener = (_event, { id }) => callback(id);
        electron_1.ipcRenderer.on('terminal-exit', listener);
        return () => {
            electron_1.ipcRenderer.removeListener('terminal-exit', listener);
        };
    },
    // Settings & AI
    getSettings: () => electron_1.ipcRenderer.invoke('get-settings'),
    saveSettings: (settings) => electron_1.ipcRenderer.invoke('save-settings', settings),
    getOllamaModels: (baseUrl) => electron_1.ipcRenderer.invoke('get-ollama-models', baseUrl),
    askAI: (prompt) => electron_1.ipcRenderer.invoke('ask-ai', prompt),
    askAIPlan: (goal, cwd) => electron_1.ipcRenderer.invoke('ask-ai-plan', { goal, cwd }),
    checkAppleIntelligence: () => electron_1.ipcRenderer.invoke('check-apple-intelligence'),
    // Utilities
    openExternal: (url) => electron_1.ipcRenderer.invoke('open-external', url),
    parseItermTheme: (xmlContent) => electron_1.ipcRenderer.invoke('parse-iterm-theme', xmlContent),
    // Session persistence
    saveSession: (sessionData) => electron_1.ipcRenderer.invoke('save-session', sessionData),
    loadSession: () => electron_1.ipcRenderer.invoke('load-session'),
    clearSession: () => electron_1.ipcRenderer.invoke('clear-session'),
    getAllTerminalCwds: () => electron_1.ipcRenderer.invoke('get-all-terminal-cwds'),
    // MCP metadata sync
    setMcpActivePane: (id) => electron_1.ipcRenderer.send('mcp-set-active-pane', id),
    setMcpPaneLabels: (labels) => electron_1.ipcRenderer.send('mcp-set-pane-labels', labels),
    setMcpHiddenPanes: (hiddenIds) => electron_1.ipcRenderer.send('mcp-set-hidden-panes', hiddenIds),
    getMcpUrl: () => electron_1.ipcRenderer.invoke('get-mcp-url'),
    getSystemMemory: () => electron_1.ipcRenderer.invoke('get-system-memory'),
});
