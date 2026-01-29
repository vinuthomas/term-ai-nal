import React, { useEffect, useRef, useLayoutEffect } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';

interface TerminalPaneProps {
  id: string;
  isActive: boolean;
  cwd?: string;
  onData: (data: string) => void; // For AI input bar feedback if needed
}

// Global store for terminal instances AND their container divs
const globalTerminals = new Map<string, { term: Terminal, fitAddon: FitAddon, containerDiv: HTMLDivElement }>();

const TerminalPane: React.FC<TerminalPaneProps> = ({ id, isActive, cwd }) => {
  const terminalRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);

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

      // Create new terminal
      term = new Terminal({
        cursorBlink: true,
        fontSize: 14,
        fontFamily: 'Menlo, Monaco, "Courier New", monospace',
        theme: {
          background: '#1e1e1e',
          foreground: '#ffffff',
        },
        allowProposedApi: true,
      });

      fitAddon = new FitAddon();
      term.loadAddon(fitAddon);
      term.open(containerDiv);
      fitAddon.fit();

      // Store in global map
      globalTerminals.set(id, { term, fitAddon, containerDiv });

      // Create PTY in main process (only once)
      window.electronAPI.createTerminal(id, cwd);
    }

    xtermRef.current = term;
    fitAddonRef.current = fitAddon;

    // Send input to PTY
    term.onData((data) => {
      window.electronAPI.sendTerminalInput(id, data);
    });

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
  }, [id]);

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

  return <div ref={terminalRef} style={{ width: '100%', height: '100%', paddingTop: '6px', boxSizing: 'border-box' }} />;
};

export default TerminalPane;
