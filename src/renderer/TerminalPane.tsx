import React, { useEffect, useRef, useLayoutEffect, useState } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import { ImageAddon } from '@xterm/addon-image';
import '@xterm/xterm/css/xterm.css';
import { themes } from './themes';

interface TerminalPaneProps {
  id: string;
  isActive: boolean;
  cwd?: string;
  onData: (data: string) => void; // For AI input bar feedback if needed
}

// Global store for terminal instances AND their container divs
const globalTerminals = new Map<string, { term: Terminal, fitAddon: FitAddon, containerDiv: HTMLDivElement }>();

// --- Terminal action helpers (called from App.tsx keyboard handlers) ---

/** Clear terminal screen and scrollback buffer (like Cmd+K in iTerm2) */
export function clearTerminal(id: string) {
  const entry = globalTerminals.get(id);
  if (!entry) return;
  // Clear scrollback then clear visible screen
  entry.term.write('\x1b[3J\x1b[H\x1b[2J');
  // Also send clear to the PTY so shell state is consistent
  window.electronAPI.sendTerminalInput(id, '\x0c');
}

/** Copy selected text to clipboard, or send SIGINT if nothing is selected */
export function copyOrInterrupt(id: string) {
  const entry = globalTerminals.get(id);
  if (!entry) return;
  const selection = entry.term.getSelection();
  if (selection) {
    navigator.clipboard.writeText(selection).catch(() => {});
  } else {
    window.electronAPI.sendTerminalInput(id, '\x03'); // Ctrl+C / SIGINT
  }
}

/** Paste clipboard text into the terminal PTY with bracketed paste support */
export async function pasteToTerminal(id: string) {
  try {
    const text = await navigator.clipboard.readText();
    if (text) {
      // Wrap in bracketed paste escape sequences so shells/editors
      // correctly handle multi-line content as pasted text (not typed input)
      const bracketedPaste = `\x1b[200~${text}\x1b[201~`;
      window.electronAPI.sendTerminalInput(id, bracketedPaste);
    }
  } catch {
    // Clipboard access denied — silently ignore
  }
}

/** Convert a Blob to base64 string efficiently using FileReader (non-blocking) */
function blobToBase64(blob: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => {
      // result is "data:<mime>;base64,<data>" — strip the prefix
      const dataUrl = reader.result as string;
      resolve(dataUrl.slice(dataUrl.indexOf(',') + 1));
    };
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/** Paste image from clipboard into the terminal using iTerm2 inline image protocol */
export async function pasteImageToTerminal(id: string): Promise<boolean> {
  try {
    const clipboardItems = await navigator.clipboard.read();
    for (const item of clipboardItems) {
      // Look for an image type in the clipboard
      const imageType = item.types.find(t => t.startsWith('image/'));
      if (imageType) {
        const blob = await item.getType(imageType);

        // Use FileReader for efficient non-blocking base64 encoding
        const base64 = await blobToBase64(blob);

        const entry = globalTerminals.get(id);
        if (!entry) return false;

        // Limit inline image size to 2 MB base64 to prevent terminal freeze.
        // Larger images block the xterm.js parser and hang the UI.
        const MAX_BASE64 = 2_000_000; // 2 MB
        if (base64.length > MAX_BASE64) {
          const sizeMB = (base64.length / 1_000_000).toFixed(1);
          const entry2 = globalTerminals.get(id);
          if (entry2) {
            entry2.term.write(`\r\n\x1b[33m[Term-AI-nal] Image too large to display inline (${sizeMB} MB, max 2 MB)\x1b[0m\r\n`);
          }
          console.warn(`Image too large for inline display (${sizeMB} MB base64), skipping.`);
          return false;
        }

        // Build the full iTerm2 inline image protocol sequence:
        //   ESC ] 1337 ; File=[params]:base64data BEL
        const params = `inline=1;size=${blob.size};preserveAspectRatio=1`;
        const imageSequence = `\x1b]1337;File=${params}:${base64}\x07`;

        // xterm.js parser operates on ~512 KB chunks internally.
        // Write the sequence using xterm's flow-control callback: each chunk
        // is only written after the previous one is fully parsed, preventing
        // the main thread from blocking and keeping the UI responsive.
        const CHUNK = 524288; // 512 KB — matches xterm.js parser buffer size
        const writeNext = (offset: number) => {
          if (offset >= imageSequence.length) return;
          const chunk = imageSequence.slice(offset, offset + CHUNK);
          // The write() callback fires after xterm.js has fully parsed this chunk
          entry.term.write(chunk, () => writeNext(offset + CHUNK));
        };
        writeNext(0);
        return true;
      }
    }
  } catch {
    // Clipboard read failed (permission denied or no image) — fall through
  }
  return false;
}

/** Select all text in the terminal */
export function selectAllTerminal(id: string) {
  const entry = globalTerminals.get(id);
  if (entry) entry.term.selectAll();
}

/** Send Ctrl+L (clear screen, preserve scrollback) to the PTY */
export function clearScreenTerminal(id: string) {
  window.electronAPI.sendTerminalInput(id, '\x0c');
}

// Prioritized Unicode-capable font stack covering macOS, Windows, and Linux.
// Nerd Fonts first (user-installed, cross-platform), then platform system fonts.
const DEFAULT_FONT_FAMILY =
  // Nerd Font variants (user-installed, best Unicode + icon coverage)
  '"MesloLGS NF", "Hack Nerd Font Mono", "FiraCode Nerd Font Mono", ' +
  '"JetBrainsMono Nerd Font Mono", "CaskaydiaCove Nerd Font Mono", ' +
  '"SauceCodePro Nerd Font Mono", ' +
  // Cross-platform developer fonts
  '"Fira Code", "JetBrains Mono", "Cascadia Code", "Cascadia Mono", ' +
  // macOS system fonts
  'Menlo, Monaco, "SF Mono", ' +
  // Windows system fonts (Consolas > Lucida Console for Unicode coverage)
  'Consolas, "Lucida Console", ' +
  // Linux system fonts
  '"DejaVu Sans Mono", "Ubuntu Mono", "Liberation Mono", "FreeMono", ' +
  // Final fallback
  '"Courier New", monospace';

const TerminalPane: React.FC<TerminalPaneProps> = ({ id, isActive, cwd }) => {
  const terminalRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);
  const [settings, setSettings] = useState<any>({ fontSize: 14, theme: 'default' });

  // Load settings
  useEffect(() => {
    const loadSettings = async () => {
      try {
        const s = await window.electronAPI.getSettings();
        setSettings(s);
      } catch (e) {
        console.error('Failed to load settings:', e);
      }
    };
    loadSettings();

    // Listen for settings updates
    const handleSettingsUpdate = () => {
      loadSettings();
    };
    window.addEventListener('settings-updated', handleSettingsUpdate);
    return () => window.removeEventListener('settings-updated', handleSettingsUpdate);
  }, []);

  useLayoutEffect(() => {
    if (!terminalRef.current) return;

    let term: Terminal;
    let fitAddon: FitAddon;
    let containerDiv: HTMLDivElement;

    // Check if terminal already exists in global store
    if (globalTerminals.has(id)) {
      const existing = globalTerminals.get(id)!;
      term = existing.term;
      fitAddon = existing.fitAddon;
      containerDiv = existing.containerDiv;

      // Move the existing container div to the new parent
      if (terminalRef.current && containerDiv.parentElement !== terminalRef.current) {
        terminalRef.current.appendChild(containerDiv);
      }

      fitAddon.fit();
    } else {
      // Create new container div that will persist
      containerDiv = document.createElement('div');
      containerDiv.style.width = '100%';
      containerDiv.style.height = '100%';
      terminalRef.current.appendChild(containerDiv);

      // Get theme from settings
      let selectedTheme;
      if (settings.theme === 'custom' && settings.customTheme) {
        selectedTheme = settings.customTheme;
      } else {
        selectedTheme = themes[settings.theme] || themes.default;
      }

      // Build font family: user override > broad Unicode-capable stack
      const fontFamily = settings.fontFamily || DEFAULT_FONT_FAMILY;

      // Create new terminal
      // unicodeVersion is a proposed API not yet in the official type defs
      const termOptions: any = {
        cursorBlink: true,
        fontSize: settings.fontSize || 14,
        fontFamily,
        unicodeVersion: '11',
        theme: selectedTheme,
        allowProposedApi: true,
      };
      term = new Terminal(termOptions);

      fitAddon = new FitAddon();
      term.loadAddon(fitAddon);

      // Load image addon for inline image rendering (iTerm2/Sixel protocols)
      const imageAddon = new ImageAddon();
      term.loadAddon(imageAddon);

      term.open(containerDiv);
      fitAddon.fit();

      // Intercept Shift+Enter: send \x0a (linefeed / ctrl+j) so that
      // OpenCode's default input_newline keybinding ("ctrl+j" / "linefeed") fires.
      // This inserts a newline in the AI prompt without submitting.
      term.attachCustomKeyEventHandler((e: KeyboardEvent) => {
        if (e.type === 'keydown' && e.key === 'Enter' && e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey) {
          window.electronAPI.sendTerminalInput(id, '\x0a');
          return false; // prevent xterm default handling
        }
        return true; // let xterm handle everything else
      });

      // Send input to PTY (register only once)
      term.onData((data) => {
        window.electronAPI.sendTerminalInput(id, data);
      });

      // Store in global map
      globalTerminals.set(id, { term, fitAddon, containerDiv });

      // Create PTY in main process (only once)
      window.electronAPI.createTerminal(id, cwd);
    }

    xtermRef.current = term;
    fitAddonRef.current = fitAddon;

    // Handle Resize via ResizeObserver for robust layout changes
    let resizeTimeout: NodeJS.Timeout;
    const resizeObserver = new ResizeObserver(() => {
      // Debounce resize to avoid excessive calls
      clearTimeout(resizeTimeout);
      resizeTimeout = setTimeout(() => {
        if (term && fitAddon) {
          // Double RAF to ensure layout is truly complete
          requestAnimationFrame(() => {
            requestAnimationFrame(() => {
              fitAddon.fit();
              // Only resize if we have valid dimensions
              if (term.cols > 0 && term.rows > 0) {
                window.electronAPI.resizeTerminal(id, term.cols, term.rows);
              }
            });
          });
        }
      }, 50);
    });

    if (terminalRef.current) {
      resizeObserver.observe(terminalRef.current);
    }

    // Initial resize with multiple attempts to ensure proper sizing
    const attemptResize = (attempt = 0) => {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          fitAddon.fit();
          if (term.cols > 0 && term.rows > 0) {
            window.electronAPI.resizeTerminal(id, term.cols, term.rows);
          } else if (attempt < 5) {
            // Retry if dimensions aren't ready yet
            setTimeout(() => attemptResize(attempt + 1), 100);
          }
        });
      });
    };
    const initialResizeTimeout = setTimeout(() => attemptResize(), 200);

    return () => {
      clearTimeout(resizeTimeout);
      clearTimeout(initialResizeTimeout);
      resizeObserver.disconnect();

      // Don't dispose terminal - keep it in global store
      // Only clean up when terminal is actually closed by closePane
    };
  }, [id]); // Remove settings from dependencies to prevent duplicate onData handlers

  // Update terminal options when settings change
  useEffect(() => {
    if (!settings || !xtermRef.current) return;

    const term = xtermRef.current;

    // Get theme from settings
    let selectedTheme;
    if (settings.theme === 'custom' && settings.customTheme) {
      selectedTheme = settings.customTheme;
    } else {
      selectedTheme = themes[settings.theme] || themes.default;
    }

    // Update font size and family
    term.options.fontSize = settings.fontSize || 14;
    term.options.fontFamily = settings.fontFamily || DEFAULT_FONT_FAMILY;

    // Update theme
    if (selectedTheme) {
      term.options.theme = selectedTheme;
    }

    // Trigger a fit to adjust to new font size
    if (fitAddonRef.current) {
      requestAnimationFrame(() => {
        fitAddonRef.current?.fit();
        if (xtermRef.current && xtermRef.current.cols > 0 && xtermRef.current.rows > 0) {
          window.electronAPI.resizeTerminal(id, xtermRef.current.cols, xtermRef.current.rows);
        }
      });
    }
  }, [settings, id]);

  // Handle incoming data
  useEffect(() => {
    const handleData = (e: CustomEvent) => {
      if (e.detail.id === id && xtermRef.current) {
        xtermRef.current.write(e.detail.data);
      }
    };

    const handleTerminalClose = (e: CustomEvent) => {
      if (e.detail.id === id) {
        // Actually dispose and clean up when terminal is closed
        const stored = globalTerminals.get(id);
        if (stored) {
          stored.term.dispose();
          stored.containerDiv.remove();
          globalTerminals.delete(id);
        }
      }
    };

    window.addEventListener('terminal-data-event' as any, handleData);
    window.addEventListener('terminal-close-event' as any, handleTerminalClose);
    return () => {
      window.removeEventListener('terminal-data-event' as any, handleData);
      window.removeEventListener('terminal-close-event' as any, handleTerminalClose);
    };
  }, [id]);

  // Handle global layout resize events
  useEffect(() => {
    const handleLayoutResize = () => {
      if (fitAddonRef.current && xtermRef.current) {
        // Double RAF ensures layout is complete
        requestAnimationFrame(() => {
          requestAnimationFrame(() => {
            fitAddonRef.current?.fit();
            if (xtermRef.current && xtermRef.current.cols > 0 && xtermRef.current.rows > 0) {
              window.electronAPI.resizeTerminal(id, xtermRef.current.cols, xtermRef.current.rows);
            }
          });
        });
      }
    };

    window.addEventListener('terminal-layout-change', handleLayoutResize);
    return () => {
      window.removeEventListener('terminal-layout-change', handleLayoutResize);
    };
  }, [id]);

  // Refit when active/layout changes
  useEffect(() => {
     if (fitAddonRef.current && xtermRef.current) {
       // Double RAF to ensure layout is complete before fitting
       requestAnimationFrame(() => {
         requestAnimationFrame(() => {
           fitAddonRef.current?.fit();
           if (xtermRef.current && xtermRef.current.cols > 0 && xtermRef.current.rows > 0) {
             window.electronAPI.resizeTerminal(id, xtermRef.current.cols, xtermRef.current.rows);
           }
         });
       });
     }
  }, [isActive, id]);

  // Focus terminal when pane becomes active
  useEffect(() => {
    if (isActive && xtermRef.current) {
      xtermRef.current.focus();
    }
  }, [isActive]);

  // Listen for focus requests (e.g., when AI palette closes)
  useEffect(() => {
    const handleFocusRequest = (e: CustomEvent) => {
      if (e.detail.id === id && xtermRef.current) {
        xtermRef.current.focus();
      }
    };

    window.addEventListener('terminal-focus-active' as any, handleFocusRequest);
    return () => {
      window.removeEventListener('terminal-focus-active' as any, handleFocusRequest);
    };
  }, [id]);

  return <div ref={terminalRef} style={{ width: '100%', height: '100%', paddingTop: '6px', paddingLeft: '5px', boxSizing: 'border-box' }} />;
};

export default TerminalPane;
