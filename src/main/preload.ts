import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('electronAPI', {
  // Terminal Management
  createTerminal: (id: string) => ipcRenderer.send('terminal-create', id),
  sendTerminalInput: (id: string, data: string) => ipcRenderer.send('terminal-input', { id, data }),
  resizeTerminal: (id: string, cols: number, rows: number) => 
    ipcRenderer.send('terminal-resize', { id, cols, rows }),
  closeTerminal: (id: string) => ipcRenderer.send('terminal-close', id),

  onTerminalData: (callback: (id: string, data: string) => void) => 
    ipcRenderer.on('terminal-data', (_event, { id, data }) => callback(id, data)),
  
  onTerminalExit: (callback: (id: string) => void) =>
    ipcRenderer.on('terminal-exit', (_event, { id }) => callback(id)),

  // Settings & AI
  getSettings: () => ipcRenderer.invoke('get-settings'),
  saveSettings: (settings: any) => ipcRenderer.invoke('save-settings', settings),
  getOllamaModels: (baseUrl: string) => ipcRenderer.invoke('get-ollama-models', baseUrl),
  askAI: (prompt: string) => ipcRenderer.invoke('ask-ai', prompt),
});
