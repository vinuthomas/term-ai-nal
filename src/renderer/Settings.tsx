import React, { useState, useEffect, useRef } from 'react';
import { X, Save, Upload, Copy, Check } from 'lucide-react';

interface SettingsProps {
  onClose: () => void;
}

const Settings: React.FC<SettingsProps> = ({ onClose }) => {
  const [activeTab, setActiveTab] = useState<'ai' | 'appearance' | 'mcp'>('ai');
  const [provider, setProvider] = useState('openai');
  const [apiKey, setApiKey] = useState('');
  const [model, setModel] = useState('');
  const [baseUrl, setBaseUrl] = useState('');
  const [ollamaModels, setOllamaModels] = useState<string[]>([]);
  const [fontSize, setFontSize] = useState(14);
  const [fontFamily, setFontFamily] = useState('');
  const [theme, setTheme] = useState('default');
  const [restoreSession, setRestoreSession] = useState(false);
  const [loading, setLoading] = useState(true);
  // MCP state
  const [mcpEnabled, setMcpEnabled] = useState(true);
  const [mcpPort, setMcpPort] = useState(57320);
  const [mcpFeatures, setMcpFeatures] = useState({
    listTerminals: true,
    getTerminalOutput: true,
    getActiveTerminalOutput: true,
    sendInputToTerminal: true,
  });
  const [mcpUrl, setMcpUrl] = useState('');
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    const load = async () => {
      const s = await window.electronAPI.getSettings();
      setProvider(s.provider || 'openai');
      setApiKey(s.apiKey || '');
      setModel(s.model || '');
      setBaseUrl(s.baseUrl || '');
      setFontSize(s.fontSize || 14);
      setFontFamily(s.fontFamily || '');
      setTheme(s.theme || 'default');
      setRestoreSession(s.restoreSession || false);
      // MCP settings
      setMcpEnabled(s.mcpEnabled !== false);
      setMcpPort(s.mcpPort || 57320);
      setMcpFeatures({
        listTerminals: s.mcpFeatures?.listTerminals !== false,
        getTerminalOutput: s.mcpFeatures?.getTerminalOutput !== false,
        getActiveTerminalOutput: s.mcpFeatures?.getActiveTerminalOutput !== false,
        sendInputToTerminal: s.mcpFeatures?.sendInputToTerminal !== false,
      });
      setLoading(false);

      const url = await window.electronAPI.getMcpUrl();
      setMcpUrl(url);

      if (s.provider === 'ollama') {
        fetchOllamaModels(s.baseUrl || 'http://localhost:11434');
      }
    };
    load();
  }, []);

  const fetchOllamaModels = async (url: string) => {
    try {
      const models = await window.electronAPI.getOllamaModels(url);
      setOllamaModels(models);
    } catch (e) {
      setOllamaModels([]);
    }
  };

  const handleProviderChange = (newProvider: string) => {
    setProvider(newProvider);
    if (newProvider === 'ollama') {
      const url = baseUrl || 'http://localhost:11434';
      setBaseUrl(url);
      fetchOllamaModels(url);
    }
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    await window.electronAPI.saveSettings({
      provider,
      apiKey,
      model,
      baseUrl,
      fontSize,
      fontFamily,
      theme,
      restoreSession,
      mcpEnabled,
      mcpPort,
      mcpFeatures,
    });
    // Trigger terminal refresh to apply new settings
    window.dispatchEvent(new CustomEvent('settings-updated'));
    // Refresh MCP URL in case port changed
    const url = await window.electronAPI.getMcpUrl();
    setMcpUrl(url);
    onClose();
  };

  const getPlaceholderModel = () => {
    switch(provider) {
        case 'openai': return 'gpt-4o';
        case 'anthropic': return 'claude-3-5-sonnet-20240620';
        case 'gemini': return 'gemini-1.5-flash';
        case 'perplexity': return 'llama-3.1-sonar-large-128k-online';
        case 'ollama': return 'llama3';
        default: return '';
    }
  }

  if (loading) return null;

  return (
    <div style={styles.overlay}>
      <div style={styles.modal}>
        <div style={styles.header}>
          <h2>Settings</h2>
          <button onClick={onClose} style={styles.closeBtn}><X size={20} /></button>
        </div>

        {/* Tabs */}
        <div style={styles.tabs}>
          <button
            onClick={() => setActiveTab('ai')}
            style={{
              ...styles.tab,
              ...(activeTab === 'ai' ? styles.tabActive : {})
            }}
          >
            AI Settings
          </button>
          <button
            onClick={() => setActiveTab('appearance')}
            style={{
              ...styles.tab,
              ...(activeTab === 'appearance' ? styles.tabActive : {})
            }}
          >
            Appearance
          </button>
          <button
            onClick={() => setActiveTab('mcp')}
            style={{
              ...styles.tab,
              ...(activeTab === 'mcp' ? styles.tabActive : {})
            }}
          >
            MCP Server
          </button>
        </div>

        {/* AI Settings Tab */}
        {activeTab === 'ai' && (
          <form onSubmit={handleSave} style={styles.form}>
          <div style={styles.group}>
            <label style={styles.label}>AI Provider</label>
            <select 
              value={provider} 
              onChange={(e) => handleProviderChange(e.target.value)} 
              style={styles.input}
            >
              <option value="openai">OpenAI</option>
              <option value="anthropic">Anthropic (Claude)</option>
              <option value="gemini">Google Gemini</option>
              <option value="perplexity">Perplexity</option>
              <option value="ollama">Ollama (Local)</option>
            </select>
          </div>

          {provider !== 'ollama' && (
            <div style={styles.group}>
              <label style={styles.label}>API Key</label>
              <input 
                type="password" 
                value={apiKey} 
                onChange={(e) => setApiKey(e.target.value)} 
                style={styles.input} 
                placeholder={`sk-...`}
              />
            </div>
          )}

          <div style={styles.group}>
            <label style={styles.label}>Model Name</label>
            {provider === 'ollama' && ollamaModels.length > 0 ? (
              <select 
                value={model} 
                onChange={(e) => setModel(e.target.value)} 
                style={styles.input}
              >
                <option value="">Select a model...</option>
                {ollamaModels.map(m => (
                  <option key={m} value={m}>{m}</option>
                ))}
              </select>
            ) : (
              <input 
                type="text" 
                value={model} 
                onChange={(e) => setModel(e.target.value)} 
                style={styles.input} 
                placeholder={getPlaceholderModel()}
              />
            )}
             <small style={{color: '#666', marginTop: '5px', display: 'block'}}>
                {provider === 'ollama' && ollamaModels.length === 0 
                  ? "Ensure Ollama is running to see installed models." 
                  : `Leave empty for default: ${getPlaceholderModel()}`}
             </small>
          </div>

          {provider === 'ollama' && (
            <div style={styles.group}>
              <label style={styles.label}>Base URL</label>
              <input 
                type="text" 
                value={baseUrl} 
                onChange={(e) => {
                  setBaseUrl(e.target.value);
                  fetchOllamaModels(e.target.value);
                }} 
                style={styles.input} 
                placeholder="http://localhost:11434"
              />
            </div>
          )}

            <button type="submit" style={styles.saveBtn}>
              <Save size={16} /> Save Settings
            </button>
          </form>
        )}

        {/* Appearance Tab */}
        {activeTab === 'appearance' && (
          <form onSubmit={handleSave} style={styles.form}>
            <div style={styles.group}>
              <label style={styles.label}>Font Size</label>
              <input
                type="range"
                min="10"
                max="24"
                value={fontSize}
                onChange={(e) => setFontSize(Number(e.target.value))}
                style={styles.slider}
              />
              <div style={{ display: 'flex', justifyContent: 'space-between', color: '#aaa', fontSize: '12px' }}>
                <span>10px</span>
                <span style={{ color: '#fff', fontWeight: 'bold' }}>{fontSize}px</span>
                <span>24px</span>
              </div>
            </div>

            <div style={styles.group}>
              <label style={styles.label}>Font Family</label>
              <input
                type="text"
                value={fontFamily}
                onChange={(e) => setFontFamily(e.target.value)}
                style={styles.input}
                placeholder="Leave empty for auto-detect (Nerd Fonts → Menlo fallback)"
              />
              <small style={{ color: '#666', marginTop: '5px', display: 'block' }}>
                e.g. "MesloLGS NF" or "Hack Nerd Font Mono" for full Unicode/icon support
              </small>
            </div>

            <div style={styles.group}>
              <label style={styles.label}>Color Theme</label>
              <select
                value={theme}
                onChange={(e) => setTheme(e.target.value)}
                style={styles.input}
              >
                <option value="default">Default</option>
                <option value="dracula">Dracula</option>
                <option value="solarized-dark">Solarized Dark</option>
                <option value="solarized-light">Solarized Light</option>
                <option value="one-dark">One Dark</option>
                <option value="monokai">Monokai</option>
                <option value="nord">Nord</option>
                <option value="gruvbox-dark">Gruvbox Dark</option>
                {theme === 'custom' && <option value="custom">Custom (Imported)</option>}
              </select>
            </div>

            <div style={styles.group}>
              <label style={styles.label}>Import iTerm2 Theme (.itermcolors)</label>
              <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
                <input
                  type="file"
                  accept=".itermcolors"
                  onChange={async (e) => {
                    const file = e.target.files?.[0];
                    if (file) {
                      try {
                        const text = await file.text();
                        const parsedTheme = await window.electronAPI.parseItermTheme(text);

                        // Save as custom theme
                        const themeName = file.name.replace('.itermcolors', '');
                        await window.electronAPI.saveSettings({
                          ...await window.electronAPI.getSettings(),
                          theme: 'custom',
                          customTheme: parsedTheme,
                          customThemeName: themeName,
                        });

                        setTheme('custom');
                        window.dispatchEvent(new CustomEvent('settings-updated'));
                        alert(`Successfully imported theme: ${themeName}`);
                      } catch (error: any) {
                        alert(`Failed to import theme: ${error.message}`);
                      }
                    }
                  }}
                  style={{ ...styles.input, cursor: 'pointer' }}
                />
              </div>
              <small style={{ color: '#666', marginTop: '5px', display: 'block' }}>
                You can download iTerm2 color schemes from{' '}
                <a
                  href="#"
                  onClick={(e) => {
                    e.preventDefault();
                    window.electronAPI.openExternal('https://iterm2colorschemes.com/');
                  }}
                  style={{ color: '#007acc', cursor: 'pointer', textDecoration: 'underline' }}
                >
                  iterm2colorschemes.com
                </a>
              </small>
            </div>

            <div style={styles.group}>
              <label style={styles.label}>Session Restore</label>
              <div
                onClick={() => setRestoreSession(!restoreSession)}
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  gap: '12px',
                  cursor: 'pointer',
                  padding: '8px 0',
                }}
              >
                <div style={{
                  width: '40px',
                  height: '22px',
                  borderRadius: '11px',
                  backgroundColor: restoreSession ? '#007acc' : '#3e3e42',
                  position: 'relative' as const,
                  transition: 'background-color 0.2s',
                  flexShrink: 0,
                }}>
                  <div style={{
                    width: '18px',
                    height: '18px',
                    borderRadius: '50%',
                    backgroundColor: '#fff',
                    position: 'absolute' as const,
                    top: '2px',
                    left: restoreSession ? '20px' : '2px',
                    transition: 'left 0.2s',
                  }} />
                </div>
                <span style={{ color: '#ddd', fontSize: '14px' }}>
                  Restore pane layout on startup
                </span>
              </div>
              <small style={{ color: '#666', marginTop: '5px', display: 'block' }}>
                When enabled, your pane layout and working directories will be restored when you reopen the app. Shell history and running processes are not preserved.
              </small>
            </div>

            <button type="submit" style={styles.saveBtn}>
              <Save size={16} /> Save Settings
            </button>
          </form>
        )}
        {/* MCP Tab */}
        {activeTab === 'mcp' && (
          <form onSubmit={handleSave} style={styles.form}>

            {/* Enable/Disable MCP */}
            <div style={styles.group}>
              <label style={styles.label}>MCP Server</label>
              <div
                onClick={() => setMcpEnabled(!mcpEnabled)}
                style={{ display: 'flex', alignItems: 'center', gap: '12px', cursor: 'pointer', padding: '8px 0' }}
              >
                <div style={{
                  width: '40px', height: '22px', borderRadius: '11px',
                  backgroundColor: mcpEnabled ? '#007acc' : '#3e3e42',
                  position: 'relative' as const, transition: 'background-color 0.2s', flexShrink: 0,
                }}>
                  <div style={{
                    width: '18px', height: '18px', borderRadius: '50%', backgroundColor: '#fff',
                    position: 'absolute' as const, top: '2px',
                    left: mcpEnabled ? '20px' : '2px', transition: 'left 0.2s',
                  }} />
                </div>
                <span style={{ color: '#ddd', fontSize: '14px' }}>
                  {mcpEnabled ? 'Enabled' : 'Disabled'}
                </span>
              </div>
              <small style={{ color: '#666', marginTop: '2px', display: 'block' }}>
                When enabled, a local MCP HTTP server allows AI agents (e.g. Claude Desktop) to read terminal output and send input.
              </small>
            </div>

            {/* MCP Endpoint URL */}
            <div style={styles.group}>
              <label style={styles.label}>MCP Endpoint URL</label>
              <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
                <input
                  type="text"
                  readOnly
                  value={mcpEnabled ? mcpUrl : '(server disabled)'}
                  style={{
                    ...styles.input,
                    flex: 1,
                    color: mcpEnabled ? '#4ec9b0' : '#666',
                    fontFamily: 'monospace',
                    cursor: 'text',
                    userSelect: 'all',
                  }}
                />
                <button
                  type="button"
                  disabled={!mcpEnabled}
                  onClick={() => {
                    if (!mcpUrl) return;
                    navigator.clipboard.writeText(mcpUrl);
                    setCopied(true);
                    setTimeout(() => setCopied(false), 2000);
                  }}
                  style={{
                    ...styles.saveBtn,
                    marginTop: 0,
                    padding: '8px 12px',
                    backgroundColor: copied ? '#388a34' : (mcpEnabled ? '#007acc' : '#3e3e42'),
                    cursor: mcpEnabled ? 'pointer' : 'not-allowed',
                    opacity: mcpEnabled ? 1 : 0.5,
                    minWidth: '90px',
                  }}
                >
                  {copied ? <><Check size={14} /> Copied</> : <><Copy size={14} /> Copy</>}
                </button>
              </div>
              <small style={{ color: '#666', marginTop: '5px', display: 'block' }}>
                Use this URL when configuring an MCP client. Bound to localhost only.
              </small>
            </div>

            {/* Port */}
            <div style={styles.group}>
              <label style={styles.label}>Port</label>
              <input
                type="number"
                min={1024}
                max={65535}
                value={mcpPort}
                onChange={(e) => setMcpPort(Number(e.target.value))}
                style={{ ...styles.input, width: '120px' }}
                disabled={!mcpEnabled}
              />
              <small style={{ color: '#666', marginTop: '5px', display: 'block' }}>
                Port the MCP server listens on (default: 57320). Changes take effect after saving. Requires the app to be restarted if the old port was in use.
              </small>
            </div>

            {/* Feature Toggles */}
            <div style={styles.group}>
              <label style={styles.label}>Enabled Tools</label>
              <small style={{ color: '#666', marginBottom: '8px', display: 'block' }}>
                Disable individual tools to restrict what AI agents can do.
              </small>
              {([
                { key: 'listTerminals', label: 'list_terminals', description: 'List open terminal panes' },
                { key: 'getTerminalOutput', label: 'get_terminal_output', description: 'Read output of a specific pane' },
                { key: 'getActiveTerminalOutput', label: 'get_active_terminal_output', description: 'Read output of the active pane' },
                { key: 'sendInputToTerminal', label: 'send_input_to_terminal', description: 'Send keystrokes/commands to a pane' },
              ] as { key: keyof typeof mcpFeatures; label: string; description: string }[]).map(({ key, label, description }) => (
                <div
                  key={key}
                  onClick={() => {
                    if (!mcpEnabled) return;
                    setMcpFeatures(prev => ({ ...prev, [key]: !prev[key] }));
                  }}
                  style={{
                    display: 'flex', alignItems: 'center', gap: '12px',
                    cursor: mcpEnabled ? 'pointer' : 'not-allowed',
                    padding: '8px 10px', borderRadius: '4px', marginBottom: '4px',
                    backgroundColor: '#1e1e1e',
                    opacity: mcpEnabled ? 1 : 0.5,
                  }}
                >
                  <div style={{
                    width: '34px', height: '18px', borderRadius: '9px',
                    backgroundColor: mcpEnabled && mcpFeatures[key] ? '#007acc' : '#3e3e42',
                    position: 'relative' as const, transition: 'background-color 0.2s', flexShrink: 0,
                  }}>
                    <div style={{
                      width: '14px', height: '14px', borderRadius: '50%', backgroundColor: '#fff',
                      position: 'absolute' as const, top: '2px',
                      left: mcpEnabled && mcpFeatures[key] ? '18px' : '2px', transition: 'left 0.2s',
                    }} />
                  </div>
                  <div>
                    <div style={{ color: '#4ec9b0', fontFamily: 'monospace', fontSize: '13px' }}>{label}</div>
                    <div style={{ color: '#888', fontSize: '11px' }}>{description}</div>
                  </div>
                </div>
              ))}
            </div>

            <button type="submit" style={styles.saveBtn}>
              <Save size={16} /> Save Settings
            </button>
          </form>
        )}
      </div>
    </div>
  );
};

const styles: { [key: string]: React.CSSProperties } = {
  overlay: {
    position: 'absolute', top: 0, left: 0, right: 0, bottom: 0,
    backgroundColor: 'rgba(0,0,0,0.7)',
    display: 'flex', alignItems: 'center', justifyContent: 'center',
    zIndex: 200,
  },
  modal: {
    backgroundColor: '#252526',
    padding: '20px',
    borderRadius: '8px',
    width: '500px',
    maxHeight: '80vh',
    overflow: 'auto',
    boxShadow: '0 10px 25px rgba(0,0,0,0.5)',
    color: 'white',
  },
  header: {
    display: 'flex', justifyContent: 'space-between', alignItems: 'center',
    marginBottom: '20px',
  },
  closeBtn: {
    background: 'none', border: 'none', color: '#aaa', cursor: 'pointer',
  },
  form: {
    display: 'flex', flexDirection: 'column', gap: '15px',
  },
  group: {
    display: 'flex', flexDirection: 'column', gap: '5px',
  },
  label: {
    fontSize: '12px', color: '#aaa',
  },
  input: {
    padding: '8px', borderRadius: '4px', border: '1px solid #3e3e42',
    backgroundColor: '#3e3e42', color: 'white', outline: 'none',
  },
  saveBtn: {
    marginTop: '10px',
    backgroundColor: '#007acc', color: 'white', border: 'none',
    padding: '10px', borderRadius: '4px', cursor: 'pointer',
    display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '8px',
    fontWeight: 'bold',
  },
  tabs: {
    display: 'flex',
    gap: '10px',
    marginBottom: '20px',
    borderBottom: '1px solid #3e3e42',
  },
  tab: {
    background: 'none',
    border: 'none',
    color: '#aaa',
    padding: '10px 15px',
    cursor: 'pointer',
    fontSize: '14px',
    borderBottom: '2px solid transparent',
    transition: 'all 0.2s',
  },
  tabActive: {
    color: '#fff',
    borderBottom: '2px solid #007acc',
  },
  slider: {
    width: '100%',
    height: '6px',
    borderRadius: '3px',
    background: '#3e3e42',
    outline: 'none',
    cursor: 'pointer',
  },
};

export default Settings;