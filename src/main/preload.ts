import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('electronAPI', {
  // Terminal Management
  createTerminal: (id: string, cwd?: string) => ipcRenderer.send('terminal-create', { id, cwd }),
  getTerminalCwd: (id: string) => ipcRenderer.invoke('terminal-get-cwd', id),
  sendTerminalInput: (id: string, data: string) => ipcRenderer.send('terminal-input', { id, data }),
  resizeTerminal: (id: string, cols: number, rows: number) =>
    ipcRenderer.send('terminal-resize', { id, cols, rows }),
  closeTerminal: (id: string) => ipcRenderer.send('terminal-close', id),

  onTerminalData: (callback: (id: string, data: string) => void) => {
    const listener = (_event: any, { id, data }: { id: string, data: string }) => callback(id, data);
    ipcRenderer.on('terminal-data', listener);
    return () => {
      ipcRenderer.removeListener('terminal-data', listener);
    };
  },

  onTerminalExit: (callback: (id: string) => void) => {
    const listener = (_event: any, { id }: { id: string }) => callback(id);
    ipcRenderer.on('terminal-exit', listener);
    return () => {
      ipcRenderer.removeListener('terminal-exit', listener);
    };
  },

  // Settings & AI
  getSettings: () => ipcRenderer.invoke('get-settings'),
  saveSettings: (settings: any) => ipcRenderer.invoke('save-settings', settings),
  getOllamaModels: (baseUrl: string) => ipcRenderer.invoke('get-ollama-models', baseUrl),
  askAI: (prompt: string) => ipcRenderer.invoke('ask-ai', prompt),

  // Utilities
  openExternal: (url: string) => ipcRenderer.invoke('open-external', url),
  parseItermTheme: (xmlContent: string) => ipcRenderer.invoke('parse-iterm-theme', xmlContent),
});
