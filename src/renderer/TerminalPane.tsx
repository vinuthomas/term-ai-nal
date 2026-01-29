import React, { useEffect, useRef } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';

interface TerminalPaneProps {
  id: string;
  isActive: boolean;
  onData: (data: string) => void; // For AI input bar feedback if needed
}

const TerminalPane: React.FC<TerminalPaneProps> = ({ id, isActive }) => {
  const terminalRef = useRef<HTMLDivElement>(null);
  const xtermRef = useRef<Terminal | null>(null);
  const fitAddonRef = useRef<FitAddon | null>(null);

  useEffect(() => {
    if (!terminalRef.current) return;

    // Initialize xterm
    const term = new Terminal({
      cursorBlink: true,
      fontSize: 14,
      fontFamily: 'Menlo, Monaco, "Courier New", monospace',
      theme: {
        background: '#1e1e1e',
        foreground: '#ffffff',
      },
      allowProposedApi: true,
    });

    const fitAddon = new FitAddon();
    term.loadAddon(fitAddon);
    fitAddonRef.current = fitAddon;

    term.open(terminalRef.current);
    fitAddon.fit();

    xtermRef.current = term;

    // Create PTY in main process
    window.electronAPI.createTerminal(id);

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
      term.dispose();
      window.electronAPI.closeTerminal(id);
    };
  }, [id]);

  // Handle incoming data
  useEffect(() => {
    const handleData = (e: CustomEvent) => {
      if (e.detail.id === id && xtermRef.current) {
        xtermRef.current.write(e.detail.data);
      }
    };

    window.addEventListener('terminal-data-event' as any, handleData);
    return () => {
      window.removeEventListener('terminal-data-event' as any, handleData);
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

  return <div ref={terminalRef} style={{ width: '100%', height: '100%' }} />;
};

export default TerminalPane;
