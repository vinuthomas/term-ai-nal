import React, { useState, useEffect } from 'react';
import { X, Save } from 'lucide-react';

interface SettingsProps {
  onClose: () => void;
}

const Settings: React.FC<SettingsProps> = ({ onClose }) => {
  const [activeTab, setActiveTab] = useState<'ai' | 'shortcuts'>('ai');
  const [provider, setProvider] = useState('openai');
  const [apiKey, setApiKey] = useState('');
  const [model, setModel] = useState('');
  const [baseUrl, setBaseUrl] = useState('');
  const [ollamaModels, setOllamaModels] = useState<string[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const load = async () => {
      const s = await window.electronAPI.getSettings();
      setProvider(s.provider || 'openai');
      setApiKey(s.apiKey || '');
      setModel(s.model || '');
      setBaseUrl(s.baseUrl || '');
      setLoading(false);

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
    await window.electronAPI.saveSettings({ provider, apiKey, model, baseUrl });
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

  const shortcuts = [
    { category: 'AI', items: [
      { keys: 'Cmd+Shift+P', description: 'Open AI Command Palette' },
    ]},
    { category: 'Pane Management', items: [
      { keys: 'Cmd+T', description: 'Split Right' },
      { keys: 'Cmd+Shift+T', description: 'Split Down' },
      { keys: 'Cmd+Alt+T', description: 'Split Left' },
      { keys: 'Cmd+Shift+Alt+T', description: 'Split Up' },
      { keys: 'Cmd+W', description: 'Close Current Pane' },
    ]},
    { category: 'Navigation', items: [
      { keys: 'Cmd+1...9', description: 'Jump to Pane by Number' },
      { keys: 'Click', description: 'Focus Pane' },
    ]},
    { category: 'General', items: [
      { keys: 'Escape', description: 'Close Overlays/Dialogs' },
    ]},
  ];

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
            onClick={() => setActiveTab('shortcuts')}
            style={{
              ...styles.tab,
              ...(activeTab === 'shortcuts' ? styles.tabActive : {})
            }}
          >
            Keyboard Shortcuts
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

        {/* Keyboard Shortcuts Tab */}
        {activeTab === 'shortcuts' && (
          <div style={styles.shortcutsContainer}>
            {shortcuts.map((section, idx) => (
              <div key={idx} style={styles.shortcutSection}>
                <h3 style={styles.shortcutCategory}>{section.category}</h3>
                {section.items.map((item, itemIdx) => (
                  <div key={itemIdx} style={styles.shortcutRow}>
                    <span style={styles.shortcutKeys}>{item.keys}</span>
                    <span style={styles.shortcutDesc}>{item.description}</span>
                  </div>
                ))}
              </div>
            ))}
            <div style={styles.shortcutNote}>
              <small style={{ color: '#888' }}>
                On Windows/Linux, use Ctrl instead of Cmd
              </small>
            </div>
          </div>
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
  shortcutsContainer: {
    display: 'flex',
    flexDirection: 'column',
    gap: '20px',
  },
  shortcutSection: {
    display: 'flex',
    flexDirection: 'column',
    gap: '8px',
  },
  shortcutCategory: {
    fontSize: '14px',
    color: '#007acc',
    marginBottom: '5px',
    fontWeight: 'bold',
  },
  shortcutRow: {
    display: 'flex',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: '8px 10px',
    backgroundColor: '#1e1e1e',
    borderRadius: '4px',
  },
  shortcutKeys: {
    fontFamily: 'monospace',
    backgroundColor: '#3e3e42',
    padding: '4px 8px',
    borderRadius: '3px',
    fontSize: '12px',
    color: '#ddd',
  },
  shortcutDesc: {
    fontSize: '13px',
    color: '#ccc',
  },
  shortcutNote: {
    marginTop: '10px',
    textAlign: 'center',
  },
};

export default Settings;