import React from 'react';
import { X } from 'lucide-react';

interface HelpProps {
  onClose: () => void;
}

const Help: React.FC<HelpProps> = ({ onClose }) => {
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
          <h2>Keyboard Shortcuts</h2>
          <button onClick={onClose} style={styles.closeBtn}><X size={20} /></button>
        </div>

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

export default Help;
