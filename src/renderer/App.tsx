import React, { useEffect, useState, useCallback } from 'react';
import { Settings as SettingsIcon, Loader, RefreshCw, Columns, Rows, X, ArrowRight, ArrowLeft, ArrowDown, ArrowUp, HelpCircle } from 'lucide-react';
import { Panel, PanelGroup, PanelResizeHandle } from './ResizablePanels';
import TerminalPane, { clearTerminal, copyOrInterrupt, pasteToTerminal, selectAllTerminal, clearScreenTerminal } from './TerminalPane';
import Settings from './Settings';
import Help from './Help';

// --- Types & Interfaces ---
declare global {
  interface Window {
    electronAPI: {
      createTerminal: (id: string, cwd?: string) => void;
      getTerminalCwd: (id: string) => Promise<string>;
      sendTerminalInput: (id: string, data: string) => void;
      resizeTerminal: (id: string, cols: number, rows: number) => void;
      closeTerminal: (id: string) => void;
      onTerminalData: (callback: (id: string, data: string) => void) => () => void;
      onTerminalExit: (callback: (id: string) => void) => () => void;
      getSettings: () => Promise<any>;
      saveSettings: (settings: any) => Promise<boolean>;
      askAI: (prompt: string) => Promise<string>;
      openExternal: (url: string) => Promise<boolean>;
      parseItermTheme: (xmlContent: string) => Promise<any>;
      saveSession: (sessionData: any) => Promise<boolean>;
      loadSession: () => Promise<any>;
      clearSession: () => Promise<boolean>;
      getAllTerminalCwds: () => Promise<Record<string, string>>;
      getOllamaModels: (baseUrl: string) => Promise<string[]>;
      setMcpActivePane: (id: string) => void;
      setMcpPaneLabels: (labels: Record<string, string>) => void;
      setMcpHiddenPanes: (hiddenIds: string[]) => void;
      getMcpUrl: () => Promise<string>;
      getSystemMemory: () => Promise<{ totalMB: number; freeMB: number }>;
    };
  }
}

// Tree Structure for Layout
type LayoutNode = {
  id: string;
  type: 'group' | 'pane';
  direction?: 'horizontal' | 'vertical'; // For groups
  children?: LayoutNode[]; // For groups
  paneId?: string; // For pane (the actual terminal ID)
  cwd?: string; // For pane (current working directory)
  paneNumber?: number; // For pane (display number for keyboard shortcuts)
  label?: string; // For pane (user-defined name)
};

// --- Helper Functions for Tree Manipulation ---

// Find the node that CONTAINS the specific paneId
const findNodeByPaneId = (root: LayoutNode, paneId: string): { node: LayoutNode, parent: LayoutNode | null, index: number } | null => {
  if (root.type === 'pane' && root.paneId === paneId) return { node: root, parent: null, index: -1 };
  if (root.children) {
    for (let i = 0; i < root.children.length; i++) {
      const result = findNodeByPaneId(root.children[i], paneId);
      if (result) {
        if (result.parent === null) return { ...result, parent: root, index: i };
        return result;
      }
    }
  }
  return null;
};

// Find pane ID by pane number
const findPaneIdByNumber = (root: LayoutNode, paneNumber: number): string | null => {
  if (root.type === 'pane' && root.paneNumber === paneNumber) return root.paneId || null;
  if (root.children) {
    for (const child of root.children) {
      const result = findPaneIdByNumber(child, paneNumber);
      if (result) return result;
    }
  }
  return null;
};

// Collect all pane IDs from layout tree
const collectPaneIds = (node: LayoutNode): string[] => {
  if (node.type === 'pane' && node.paneId) return [node.paneId];
  if (node.children) return node.children.flatMap(collectPaneIds);
  return [];
};

// Get the highest pane number in the layout tree
const getMaxPaneNumber = (node: LayoutNode): number => {
  if (node.type === 'pane') return node.paneNumber || 0;
  if (node.children) return Math.max(0, ...node.children.map(getMaxPaneNumber));
  return 0;
};

// Assign new unique pane IDs to a restored layout (avoids conflicts with timestamp-based IDs)
const reassignPaneIds = (node: LayoutNode): { node: LayoutNode, paneIds: string[] } => {
  if (node.type === 'pane') {
    const newPaneId = `term-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
    return {
      node: { ...node, id: `node-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`, paneId: newPaneId },
      paneIds: [newPaneId]
    };
  }
  if (node.children) {
    const results = node.children.map(reassignPaneIds);
    return {
      node: { ...node, children: results.map(r => r.node) },
      paneIds: results.flatMap(r => r.paneIds)
    };
  }
  return { node, paneIds: [] };
};

// Update CWDs in a layout tree from a cwdMap (keyed by pane index order)
const applyCwdsToLayout = (node: LayoutNode, cwds: string[], index: { i: number }): LayoutNode => {
  if (node.type === 'pane') {
    const cwd = cwds[index.i] || undefined;
    index.i++;
    return { ...node, cwd };
  }
  if (node.children) {
    return { ...node, children: node.children.map(c => applyCwdsToLayout(c, cwds, index)) };
  }
  return node;
};

const App: React.FC = () => {
  // --- State ---
  // Initial Tree: One Root Group containing One Pane
  const [layout, setLayout] = useState<LayoutNode>({
    id: 'root',
    type: 'group',
    direction: 'horizontal',
    children: []
  });

  const [activePaneId, setActivePaneId] = useState<string>('');
  const [terminals, setTerminals] = useState<string[]>([]); // Keep track of active terminal IDs for cleanup
  const [nextPaneNumber, setNextPaneNumber] = useState<number>(2); // Counter for pane numbers
  const [paneLabels, setPaneLabels] = useState<Record<string, string>>({}); // Custom labels for panes
  const [mcpHiddenPanes, setMcpHiddenPanes] = useState<Set<string>>(new Set()); // Panes hidden from MCP
  const [mcpServerEnabled, setMcpServerEnabled] = useState<boolean>(true); // Mirrors settings.mcpEnabled
  const [renamingPaneId, setRenamingPaneId] = useState<string | null>(null); // ID of pane being renamed
  const [renameValue, setRenameValue] = useState<string>(''); // Current rename input value

  const [aiInput, setAiInput] = useState('');
  const [originalRequest, setOriginalRequest] = useState('');
  const [refinementText, setRefinementText] = useState('');
  const [showAiBar, setShowAiBar] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const [showHelp, setShowHelp] = useState(false);
  const [pendingCommand, setPendingCommand] = useState<string | null>(null);
  const [pendingExplanation, setPendingExplanation] = useState<string | null>(null);
  const [isProcessing, setIsProcessing] = useState(false);
  const [promptHistory, setPromptHistory] = useState<string[]>([]);
  const [historyIndex, setHistoryIndex] = useState<number>(-1);

  const refineInputRef = React.useRef<HTMLInputElement>(null);
  const aiInputRef = React.useRef<HTMLInputElement>(null);

  // Load prompt history from localStorage on mount
  useEffect(() => {
    try {
      const saved = localStorage.getItem('ai-prompt-history');
      if (saved) {
        setPromptHistory(JSON.parse(saved));
      }
    } catch (e) {
      console.error('Failed to load prompt history:', e);
    }
  }, []);

  // Save prompt history to localStorage when it changes
  useEffect(() => {
    try {
      localStorage.setItem('ai-prompt-history', JSON.stringify(promptHistory));
    } catch (e) {
      console.error('Failed to save prompt history:', e);
    }
  }, [promptHistory]);

  // --- Sync MCP metadata to main process ---
  useEffect(() => {
    window.electronAPI.setMcpActivePane(activePaneId);
  }, [activePaneId]);

  useEffect(() => {
    window.electronAPI.setMcpPaneLabels(paneLabels);
  }, [paneLabels]);

  useEffect(() => {
    window.electronAPI.setMcpHiddenPanes(Array.from(mcpHiddenPanes));
  }, [mcpHiddenPanes]);

  // Load mcpEnabled from settings; refresh whenever settings are saved
  useEffect(() => {
    const sync = async () => {
      const s = await window.electronAPI.getSettings();
      setMcpServerEnabled(s.mcpEnabled !== false);
    };
    sync();
    window.addEventListener('settings-updated', sync);
    return () => window.removeEventListener('settings-updated', sync);
  }, []);

  // --- Session Restore on Mount ---
  const [sessionRestored, setSessionRestored] = useState(false);

  useEffect(() => {
    const restoreSession = async () => {
      try {
        const settings = await window.electronAPI.getSettings();
        if (!settings.restoreSession) {
          const freshId = 'term-1';
          setLayout({ id: 'root', type: 'group', direction: 'horizontal', children: [{ id: 'node-1', type: 'pane', paneId: freshId, paneNumber: 1 }] });
          setTerminals([freshId]);
          setActivePaneId(freshId);
          setSessionRestored(true);
          return;
        }

        const session = await window.electronAPI.loadSession();
        if (!session || !session.layout) {
          const freshId = 'term-1';
          setLayout({ id: 'root', type: 'group', direction: 'horizontal', children: [{ id: 'node-1', type: 'pane', paneId: freshId, paneNumber: 1 }] });
          setTerminals([freshId]);
          setActivePaneId(freshId);
          setSessionRestored(true);
          return;
        }

        // Reassign fresh pane IDs to the restored layout
        const { node: restoredLayout, paneIds } = reassignPaneIds(session.layout);

        // Apply saved CWDs to the restored layout (in pane order)
        const layoutWithCwds = session.cwds
          ? applyCwdsToLayout(restoredLayout, session.cwds, { i: 0 })
          : restoredLayout;

        // Restore pane labels if saved (map old pane IDs -> new pane IDs by position)
        if (session.paneLabels && session.layout) {
          const oldPaneIds = collectPaneIds(session.layout);
          const restoredLabels: Record<string, string> = {};
          oldPaneIds.forEach((oldId, i) => {
            const newId = paneIds[i];
            if (newId && session.paneLabels[oldId]) {
              restoredLabels[newId] = session.paneLabels[oldId];
            }
          });
          setPaneLabels(restoredLabels);
        }

        // Apply state
        setLayout(layoutWithCwds);
        setTerminals(paneIds);
        const savedIndex = session.activePaneIndex ?? 0;
        setActivePaneId(paneIds[savedIndex] || paneIds[0] || '');
        setNextPaneNumber(getMaxPaneNumber(layoutWithCwds) + 1);

        // Do NOT clear the session here — the debounced save effect will
        // immediately overwrite it with the new (reassigned) pane IDs,
        // keeping session.json always current for the before-quit handler.
      } catch (e) {
        console.error('Failed to restore session:', e);
        // Fallback: boot with a fresh single pane so the UI is never blank
        const freshId = 'term-1';
        setLayout({ id: 'root', type: 'group', direction: 'horizontal', children: [{ id: 'node-1', type: 'pane', paneId: freshId, paneNumber: 1 }] });
        setTerminals([freshId]);
        setActivePaneId(freshId);
      } finally {
        setSessionRestored(true);
      }
    };

    restoreSession();
  }, []);

  // --- Session Save on Layout Changes (debounced) ---
  useEffect(() => {
    // Don't save until the session restore attempt is complete, to avoid
    // overwriting the on-disk session with the empty initial layout.
    if (!sessionRestored) return;

    const saveSessionDebounced = setTimeout(async () => {
      try {
        const settings = await window.electronAPI.getSettings();
        if (!settings.restoreSession) return;

        // Get current CWDs from all terminals
        const cwdMap = await window.electronAPI.getAllTerminalCwds();

        // Collect pane IDs in layout order and map to CWDs
        const paneIds = collectPaneIds(layout);
        const cwds = paneIds.map(id => cwdMap[id] || '');

        await window.electronAPI.saveSession({
          layout,
          cwds,
          activePaneIndex: paneIds.indexOf(activePaneId),
          paneLabels,
        });
      } catch (e) {
        console.error('Failed to save session:', e);
      }
    }, 1000); // Debounce 1 second

    return () => clearTimeout(saveSessionDebounced);
  }, [layout, activePaneId, paneLabels, sessionRestored]);

  // --- Listeners ---
  useEffect(() => {
    const cleanupData = window.electronAPI.onTerminalData((id, data) => {
      const event = new CustomEvent('terminal-data-event', { detail: { id, data } });
      window.dispatchEvent(event);
    });

    // Handle window resize
    let resizeTimeout: NodeJS.Timeout;
    const handleWindowResize = () => {
      clearTimeout(resizeTimeout);
      resizeTimeout = setTimeout(() => {
        window.dispatchEvent(new CustomEvent('terminal-layout-change'));
      }, 100);
    };

    window.addEventListener('resize', handleWindowResize);
    return () => {
      cleanupData();
      window.removeEventListener('resize', handleWindowResize);
      clearTimeout(resizeTimeout);
    };
  }, []);

  // Handle terminal exit separately to avoid dependency issues
  useEffect(() => {
    const cleanupExit = window.electronAPI.onTerminalExit((id) => {
      const shouldClose = window.confirm(
        'Terminal session ended. Would you like to close this pane?'
      );
      if (shouldClose) {
        // Use setLayout directly to avoid dependency issues
        setLayout(prevLayout => {
          const removeByPaneId = (node: LayoutNode): LayoutNode | null => {
            if (node.type === 'pane' && node.paneId === id) return null;
            if (node.children) {
              const newChildren = node.children
                .map(removeByPaneId)
                .filter((n): n is LayoutNode => n !== null);

              if (newChildren.length === 0) return null;
              if (newChildren.length === 1 && node.id !== 'root') return newChildren[0];
              return { ...node, children: newChildren };
            }
            return node;
          };

          const result = removeByPaneId(prevLayout);
          return result || prevLayout;
        });

        setTerminals(prev => prev.filter(t => t !== id));
      }
    });

    return () => cleanupExit();
  }, []);

  // --- Layout Actions ---

  const splitPane = async (direction: 'horizontal' | 'vertical', position: 'before' | 'after' = 'after') => {
    const newPaneId = `term-${Date.now()}`;
    const newNodeId = `node-${Date.now()}`;
    const paneNumber = nextPaneNumber;

    // Get the CWD of the currently active pane
    let cwd: string | undefined;
    try {
      cwd = await window.electronAPI.getTerminalCwd(activePaneId);
    } catch (error) {
      console.error('Failed to get CWD:', error);
    }

    const newPaneNode: LayoutNode = {
      id: newNodeId,
      type: 'pane',
      paneId: newPaneId,
      cwd: cwd,
      paneNumber: paneNumber
    };

    setTerminals(prev => [...prev, newPaneId]);
    setActivePaneId(newPaneId);
    setNextPaneNumber(prev => prev + 1);

    setLayout(prevLayout => {
      // Deep clone to avoid mutation
      const newRoot = JSON.parse(JSON.stringify(prevLayout));
      const target = findNodeByPaneId(newRoot, activePaneId);

      if (!target || !target.parent) {
        return newRoot;
      }

      const { node, parent, index } = target;

      if (parent.direction === direction) {
        // Same direction - insert before or after current pane
        const insertIndex = position === 'after' ? index + 1 : index;
        parent.children!.splice(insertIndex, 0, newPaneNode);
      } else {
        // Different direction - create new group
        const newGroup: LayoutNode = {
          id: `group-${Date.now()}`,
          type: 'group',
          direction: direction,
          children: position === 'after' ? [node, newPaneNode] : [newPaneNode, node]
        };
        parent.children![index] = newGroup;
      }

      return newRoot;
    });

    // Trigger resize after layout settles
    setTimeout(() => {
      window.dispatchEvent(new CustomEvent('terminal-layout-change'));
    }, 100);
  };

  const closePane = (targetPaneId: string) => {
    if (terminals.length <= 1) return;

    // Dispatch event to clean up terminal from global store
    window.dispatchEvent(new CustomEvent('terminal-close-event', { detail: { id: targetPaneId } }));

    // Close the PTY
    window.electronAPI.closeTerminal(targetPaneId);

    setLayout(prevLayout => {
      const removeByPaneId = (node: LayoutNode): LayoutNode | null => {
        if (node.type === 'pane' && node.paneId === targetPaneId) return null;
        if (node.children) {
          const newChildren = node.children
            .map(removeByPaneId)
            .filter((n): n is LayoutNode => n !== null);

          if (newChildren.length === 0) return null;
          if (newChildren.length === 1 && node.id !== 'root') return newChildren[0]; // Hoist
          return { ...node, children: newChildren };
        }
        return node;
      };

      const result = removeByPaneId(prevLayout);
      return result || prevLayout;
    });

    setTerminals(prev => prev.filter(t => t !== targetPaneId));
    if (activePaneId === targetPaneId) {
       const remaining = terminals.filter(t => t !== targetPaneId);
       if (remaining.length > 0) setActivePaneId(remaining[0]);
    }

    // Clean up label for closed pane
    setPaneLabels(prev => {
      const next = { ...prev };
      delete next[targetPaneId];
      return next;
    });

    // Trigger resize after layout settles
    setTimeout(() => {
      window.dispatchEvent(new CustomEvent('terminal-layout-change'));
    }, 100);
  };

  // --- Rename Logic ---
  const startRenaming = (paneId: string) => {
    setRenamingPaneId(paneId);
    setRenameValue(paneLabels[paneId] || '');
  };

  const commitRename = (paneId: string) => {
    const trimmed = renameValue.trim();
    setPaneLabels(prev => {
      if (trimmed) return { ...prev, [paneId]: trimmed };
      // Remove label if empty (revert to default)
      const next = { ...prev };
      delete next[paneId];
      return next;
    });
    setRenamingPaneId(null);
    setRenameValue('');
  };

  const cancelRename = () => {
    setRenamingPaneId(null);
    setRenameValue('');
  };

  // --- AI Logic ---
  const processAIRequest = async (prompt: string) => {
    setIsProcessing(true);
    try {
      // Get current working directory for context
      let cwd = '';
      try {
        cwd = await window.electronAPI.getTerminalCwd(activePaneId);
      } catch (e) {
        console.error('Failed to get CWD:', e);
      }

      // Enhance prompt with context
      const contextualPrompt = cwd
        ? `[Current Directory: ${cwd}]\n${prompt}`
        : prompt;

      const response = await window.electronAPI.askAI(contextualPrompt);
      const cmdMatch = response.match(/COMMAND:\s*([\s\S]*?)(?=\nEXPLANATION:|$)/i);
      const expMatch = response.match(/EXPLANATION:\s*([\s\S]*?)$/i);
      const cmd = cmdMatch ? cmdMatch[1].trim() : response.trim();
      const exp = expMatch ? expMatch[1].trim() : '';
      setPendingCommand(cmd);
      setPendingExplanation(exp);
    } catch (err) {
      setPendingCommand(`echo "Error connecting to AI service."`);
      setPendingExplanation(null);
    } finally {
      setIsProcessing(false);
    }
  };

  const handleAiSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!aiInput.trim()) return;
    setOriginalRequest(aiInput);
    // Add to history (avoid duplicates and limit to 50 items)
    setPromptHistory(prev => {
      const filtered = prev.filter(p => p !== aiInput.trim());
      const newHistory = [aiInput.trim(), ...filtered].slice(0, 50);
      return newHistory;
    });
    setHistoryIndex(-1);
    await processAIRequest(aiInput);
    setAiInput('');
  };

  const handleRefineSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!refinementText.trim()) return;
    const contextPrompt = `Original Request: "${originalRequest}"
    Your Previous Suggestion: "${pendingCommand}"
    User Feedback: "${refinementText}"
    Based on this feedback, provide the corrected command.`;
    await processAIRequest(contextPrompt);
    setRefinementText('');
  };

  const executeCommand = useCallback(() => {
    if (pendingCommand) {
      window.electronAPI.sendTerminalInput(activePaneId, pendingCommand + '\n');
      setPendingCommand(null);
      setPendingExplanation(null);
      setShowAiBar(false);
      setRefinementText('');
      // Focus the active terminal after closing AI bar
      setTimeout(() => {
        window.dispatchEvent(new CustomEvent('terminal-focus-active', { detail: { id: activePaneId } }));
      }, 50);
    }
  }, [pendingCommand, activePaneId]);

  const cancelCommand = useCallback(() => {
    setPendingCommand(null);
    setPendingExplanation(null);
    setRefinementText('');
    setShowAiBar(false);
    // Focus the active terminal after closing AI bar
    setTimeout(() => {
      window.dispatchEvent(new CustomEvent('terminal-focus-active', { detail: { id: activePaneId } }));
    }, 50);
  }, [activePaneId]);

  // Handle AI bar keyboard shortcuts
  useEffect(() => {
    if (!showAiBar) return;

    const handleAiBarKeyDown = (e: KeyboardEvent) => {
      // Don't interfere if user is typing in an input
      const target = e.target as HTMLElement;
      const isInputFocused = target.tagName === 'INPUT';

      // Enter key when results are shown - execute command
      if (e.key === 'Enter' && pendingCommand && !isInputFocused) {
        e.preventDefault();
        executeCommand();
        return;
      }

      // Up/Down arrow navigation through history (only in initial input, not refine)
      if ((e.key === 'ArrowUp' || e.key === 'ArrowDown') && !pendingCommand && isInputFocused) {
        e.preventDefault();
        if (promptHistory.length === 0) return;

        if (e.key === 'ArrowUp') {
          const newIndex = historyIndex < promptHistory.length - 1 ? historyIndex + 1 : historyIndex;
          setHistoryIndex(newIndex);
          setAiInput(promptHistory[newIndex] || '');
        } else if (e.key === 'ArrowDown') {
          const newIndex = historyIndex > 0 ? historyIndex - 1 : -1;
          setHistoryIndex(newIndex);
          setAiInput(newIndex === -1 ? '' : promptHistory[newIndex]);
        }
        return;
      }

      // Auto-focus refine input when results are shown and user types any other key
      if (pendingCommand && !isInputFocused && e.key.length === 1 && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault();
        if (refineInputRef.current) {
          refineInputRef.current.focus();
          // Append the typed character
          setRefinementText(prev => prev + e.key);
        }
      }
    };

    window.addEventListener('keydown', handleAiBarKeyDown);
    return () => window.removeEventListener('keydown', handleAiBarKeyDown);
  }, [showAiBar, pendingCommand, promptHistory, historyIndex, executeCommand]);

  // --- Shortcuts ---
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // AI Command Palette (Cmd+Shift+P or Ctrl+Shift+P)
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && (e.key === 'P' || e.key === 'p')) {
        e.preventDefault();
        setShowAiBar(true);
      }
      // Switch to pane by number (Cmd+1 through Cmd+9)
      if ((e.metaKey || e.ctrlKey) && !e.shiftKey && /^[1-9]$/.test(e.key)) {
        e.preventDefault();
        const paneNumber = parseInt(e.key, 10);
        const paneId = findPaneIdByNumber(layout, paneNumber);
        if (paneId) {
          setActivePaneId(paneId);
        }
      }
      // Split panes with Cmd+T (like "new Tab")
      if ((e.metaKey || e.ctrlKey) && (e.key === 't' || e.key === 'T')) {
        e.preventDefault();
        if (e.shiftKey && e.altKey) {
           // Cmd+Shift+Alt+T: split up
           splitPane('vertical', 'before');
        } else if (e.shiftKey) {
           // Cmd+Shift+T: split down
           splitPane('vertical', 'after');
        } else if (e.altKey) {
           // Cmd+Alt+T: split left
           splitPane('horizontal', 'before');
        } else {
           // Cmd+T: split right
           splitPane('horizontal', 'after');
        }
      }
      // Close Pane (Cmd+W)
      if ((e.metaKey || e.ctrlKey) && (e.key === 'w' || e.key === 'W')) {
        e.preventDefault();
        closePane(activePaneId);
      }

      // Terminal shortcuts — only when AI bar/settings/help are not open
      if (!showAiBar && !showSettings && !showHelp) {
        // Cmd+K — clear terminal screen + scrollback (like iTerm2)
        if (e.metaKey && (e.key === 'k' || e.key === 'K') && !e.shiftKey && !e.ctrlKey) {
          e.preventDefault();
          clearTerminal(activePaneId);
          return;
        }
        // Cmd+L — clear screen (preserve scrollback, like Ctrl+L)
        if (e.metaKey && (e.key === 'l' || e.key === 'L') && !e.shiftKey && !e.ctrlKey) {
          e.preventDefault();
          clearScreenTerminal(activePaneId);
          return;
        }
        // Cmd+C — copy selection if any, otherwise send SIGINT
        if (e.metaKey && (e.key === 'c' || e.key === 'C') && !e.shiftKey && !e.ctrlKey) {
          e.preventDefault();
          copyOrInterrupt(activePaneId);
          return;
        }
        // Cmd+V — paste clipboard into terminal
        if (e.metaKey && (e.key === 'v' || e.key === 'V') && !e.shiftKey && !e.ctrlKey) {
          e.preventDefault();
          pasteToTerminal(activePaneId);
          return;
        }
        // Cmd+A — select all terminal text
        if (e.metaKey && (e.key === 'a' || e.key === 'A') && !e.shiftKey && !e.ctrlKey) {
          e.preventDefault();
          selectAllTerminal(activePaneId);
          return;
        }
      }

      if (e.key === 'Escape') {
        const wasAiBarOpen = showAiBar;
        setShowAiBar(false);
        setPendingCommand(null);
        setPendingExplanation(null);
        setShowSettings(false);
        setShowHelp(false);
        setRefinementText('');
        // Focus the active terminal if AI bar was open
        if (wasAiBarOpen) {
          setTimeout(() => {
            window.dispatchEvent(new CustomEvent('terminal-focus-active', { detail: { id: activePaneId } }));
          }, 50);
        }
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [activePaneId, terminals, layout, showAiBar, showSettings, showHelp]);

  // --- Recursive Renderer ---
  const renderNode = (node: LayoutNode) => {
    if (node.type === 'pane' && node.paneId) {
      const paneId = node.paneId;
      const isActive = activePaneId === paneId;
      const isRenaming = renamingPaneId === paneId;
      const label = paneLabels[paneId] || `Terminal ${node.paneNumber ?? ''}`.trim();

      return (
        <div
          key={paneId}
          style={{ width: '100%', height: '100%', position: 'relative', display: 'flex', flexDirection: 'column' }}
          onClick={() => setActivePaneId(paneId)}
        >
          {/* Pane title bar */}
          <div style={{
            ...styles.paneTitleBar,
            borderTopColor: isActive ? '#50fa7b' : '#333',
          }}>
            {isRenaming ? (
              <input
                autoFocus
                style={styles.renameInput}
                value={renameValue}
                onChange={(e) => setRenameValue(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') { e.stopPropagation(); commitRename(paneId); }
                  if (e.key === 'Escape') { e.stopPropagation(); cancelRename(); }
                }}
                onBlur={() => commitRename(paneId)}
                onClick={(e) => e.stopPropagation()}
                placeholder="Terminal name..."
              />
            ) : (
              <span
                style={styles.paneTitleLabel}
                title="Double-click to rename"
                onDoubleClick={(e) => { e.stopPropagation(); startRenaming(paneId); }}
              >
                {label}
              </span>
            )}
            {/* MCP visibility toggle */}
            {(() => {
              const isMcpVisible = mcpServerEnabled && !mcpHiddenPanes.has(paneId);
              const isDisabledByServer = !mcpServerEnabled;
              return (
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    if (isDisabledByServer) return;
                    setMcpHiddenPanes(prev => {
                      const next = new Set(prev);
                      if (next.has(paneId)) next.delete(paneId);
                      else next.add(paneId);
                      return next;
                    });
                  }}
                  title={
                    isDisabledByServer
                      ? 'MCP server is disabled in Settings'
                      : isMcpVisible
                        ? 'Visible to MCP — click to hide'
                        : 'Hidden from MCP — click to show'
                  }
                  style={{
                    background: 'none',
                    border: `1px solid ${isMcpVisible ? '#388a34' : '#555'}`,
                    borderRadius: '3px',
                    color: isMcpVisible ? '#4ec9b0' : '#555',
                    fontSize: '10px',
                    fontWeight: 'bold',
                    fontFamily: 'monospace',
                    padding: '1px 5px',
                    cursor: isDisabledByServer ? 'default' : 'pointer',
                    lineHeight: '14px',
                    backgroundColor: isMcpVisible ? 'rgba(56,138,52,0.15)' : 'transparent',
                    transition: 'all 0.15s',
                    flexShrink: 0,
                    opacity: isDisabledByServer ? 0.35 : 1,
                  }}
                >
                  MCP
                </button>
              );
            })()}
            {/* Close button */}
            {terminals.length > 1 && (
              <button
                onClick={(e) => { e.stopPropagation(); closePane(paneId); }}
                style={styles.closePaneBtn}
                title="Close pane"
              >
                <X size={12} />
              </button>
            )}
          </div>
          <div style={{ flex: 1, overflow: 'hidden', minHeight: 0 }}>
            <TerminalPane
               id={paneId}
               isActive={isActive}
               cwd={node.cwd}
               onData={() => {}}
            />
          </div>
        </div>
      );
    }

    if (node.type === 'group' && node.children) {
      const direction = node.direction || 'horizontal';
      const handleStyle = direction === 'horizontal'
        ? styles.resizeHandleHorizontal
        : styles.resizeHandleVertical;

      return (
        <PanelGroup
          key={node.id}
          orientation={direction}
          style={{ width: '100%', height: '100%' }}
        >
          {node.children.map((child, i) => (
            <React.Fragment key={child.type === 'pane' ? child.paneId : child.id}>
              <Panel minSize={10} style={{ overflow: 'hidden' }}>
                {renderNode(child)}
              </Panel>
              {i < (node.children?.length ?? 0) - 1 && (
                 <PanelResizeHandle style={handleStyle} />
              )}
            </React.Fragment>
          ))}
        </PanelGroup>
      );
    }
    return null;
  };

  return (
    <div style={{ position: 'relative', height: '100%', width: '100%', display: 'flex', flexDirection: 'column', backgroundColor: '#1e1e1e' }}>
      {/* Header */}
      <div style={styles.dragRegion} />

      {/* Toolbar */}
      <div style={styles.toolbar}>
        <button onClick={() => splitPane('horizontal', 'after')} style={styles.toolBtn} title="Split Right (Cmd+T)">
            <ArrowRight size={18} color="#999" />
        </button>
        <button onClick={() => splitPane('horizontal', 'before')} style={styles.toolBtn} title="Split Left (Cmd+Alt+T)">
            <ArrowLeft size={18} color="#999" />
        </button>
        <button onClick={() => splitPane('vertical', 'after')} style={styles.toolBtn} title="Split Down (Cmd+Shift+T)">
            <ArrowDown size={18} color="#999" />
        </button>
        <button onClick={() => splitPane('vertical', 'before')} style={styles.toolBtn} title="Split Up (Cmd+Shift+Alt+T)">
            <ArrowUp size={18} color="#999" />
        </button>
        <div style={styles.divider} />
        <button onClick={() => setShowHelp(true)} style={styles.toolBtn} title="Keyboard Shortcuts">
            <HelpCircle size={20} color="#999" />
        </button>
        <button onClick={() => setShowSettings(true)} style={styles.toolBtn} title="Settings">
            <SettingsIcon size={20} color="#999" />
        </button>
      </div>

      {showHelp && <Help onClose={() => {
        setShowHelp(false);
        // Focus the active terminal after closing help
        setTimeout(() => {
          window.dispatchEvent(new CustomEvent('terminal-focus-active', { detail: { id: activePaneId } }));
        }, 50);
      }} />}

      {showSettings && <Settings onClose={() => {
        setShowSettings(false);
        // Focus the active terminal after closing settings
        setTimeout(() => {
          window.dispatchEvent(new CustomEvent('terminal-focus-active', { detail: { id: activePaneId } }));
        }, 50);
      }} />}

      {/* Layout Root */}
      <div style={styles.terminalContainer}>
        {sessionRestored ? renderNode(layout) : null}
      </div>

      {/* AI Bar */}
      {showAiBar && (
        <div style={styles.aiBarContainer}>
          <div style={styles.aiBar}>
            {isProcessing ? (
               <div style={{display: 'flex', alignItems: 'center', gap: '10px', color: '#aaa'}}>
                 <Loader className="spin" size={16} /> Thinking...
               </div>
            ) : !pendingCommand ? (
              <form onSubmit={handleAiSubmit} style={{ width: '100%' }}>
                <input
                  ref={aiInputRef}
                  autoFocus
                  style={styles.input}
                  placeholder={`AI Command for ${activePaneId}...`}
                  value={aiInput}
                  onChange={(e) => setAiInput(e.target.value)}
                />
              </form>
            ) : (
              <div style={styles.reviewContainer}>
                <div style={styles.reviewTitle}>Review Command ({activePaneId}):</div>
                {pendingExplanation && <div style={styles.explanationText}>{pendingExplanation}</div>}
                <code style={styles.commandCode}>{pendingCommand}</code>
                <form onSubmit={handleRefineSubmit} style={styles.refineForm}>
                  <div style={{position: 'relative', width: '100%'}}>
                    <input
                        ref={refineInputRef}
                        style={styles.refineInput}
                        placeholder="Not what you wanted? Refine request..."
                        value={refinementText}
                        onChange={(e) => setRefinementText(e.target.value)}
                    />
                    <button type="submit" style={styles.refineSubmitBtn} disabled={!refinementText.trim()}>
                        <RefreshCw size={14} />
                    </button>
                  </div>
                </form>
                <div style={styles.buttonGroup}>
                  <button onClick={executeCommand} style={styles.executeButton}>Execute</button>
                  <button onClick={cancelCommand} style={styles.cancelButton}>Cancel</button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
      
      <style>{`
        .spin { animation: spin 1s linear infinite; }
        @keyframes spin { 100% { transform: rotate(360deg); } }
      `}</style>
    </div>
  );
};

const styles: { [key: string]: React.CSSProperties & { WebkitAppRegion?: string } } = {
  dragRegion: {
    height: '30px',
    width: '100%',
    WebkitAppRegion: 'drag' as any,
    zIndex: 10,
    flexShrink: 0,
    position: 'absolute',
    top: 0, left: 0, right: '200px', // Space for expanded toolbar
  },
  toolbar: {
    position: 'absolute',
    top: '8px',
    right: '15px',
    zIndex: 100,
    display: 'flex',
    gap: '8px',
    alignItems: 'center',
    WebkitAppRegion: 'no-drag' as any,
  },
  toolBtn: {
    background: 'none',
    border: 'none',
    cursor: 'pointer',
    padding: '5px',
    display: 'flex',
    alignItems: 'center',
  },
  divider: {
    width: '1px',
    height: '16px',
    backgroundColor: '#444',
    margin: '0 5px',
  },
  terminalContainer: {
    flex: 1,
    marginTop: '38px', // Space for header and toolbar
    display: 'flex',
    flexDirection: 'column',
    overflow: 'hidden',
    width: '100%',
    height: 'calc(100% - 38px)',
    position: 'relative',
  },
  resizeHandleHorizontal: {
    backgroundColor: '#333',
    width: '4px',
    flexShrink: 0,
    cursor: 'col-resize',
    zIndex: 20,
    transition: 'background-color 0.2s',
  },
  resizeHandleVertical: {
    backgroundColor: '#333',
    height: '4px',
    flexShrink: 0,
    cursor: 'row-resize',
    zIndex: 20,
    transition: 'background-color 0.2s',
  },
  paneTitleBar: {
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'space-between',
      height: '24px',
      minHeight: '24px',
      paddingLeft: '8px',
      paddingRight: '4px',
      backgroundColor: '#252525',
      borderTop: '2px solid #333',
      userSelect: 'none',
      flexShrink: 0,
      zIndex: 5,
  },
  paneTitleLabel: {
      flex: 1,
      color: 'rgba(255,255,255,0.55)',
      fontSize: '11px',
      fontFamily: 'monospace',
      overflow: 'hidden',
      textOverflow: 'ellipsis',
      whiteSpace: 'nowrap',
      cursor: 'default',
  },
  renameInput: {
      flex: 1,
      background: 'transparent',
      border: 'none',
      borderBottom: '1px solid #50fa7b',
      color: '#fff',
      fontSize: '11px',
      fontFamily: 'monospace',
      outline: 'none',
      padding: '0 2px',
      minWidth: 0,
  },
  closePaneBtn: {
      flexShrink: 0,
      background: 'none',
      color: 'rgba(255,255,255,0.4)',
      border: 'none',
      borderRadius: '50%',
      width: '18px',
      height: '18px',
      cursor: 'pointer',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      marginLeft: '4px',
  },
  aiBarContainer: {
    position: 'absolute',
    top: '50px',
    left: '50%',
    transform: 'translateX(-50%)',
    width: '80%',
    maxWidth: '600px',
    zIndex: 200,
  },
  aiBar: {
    backgroundColor: '#2d2d2d',
    borderRadius: '8px',
    padding: '15px',
    boxShadow: '0 4px 20px rgba(0,0,0,0.5)',
    border: '1px solid #444',
  },
  input: {
    width: '100%',
    background: 'transparent',
    border: 'none',
    color: 'white',
    fontSize: '16px',
    outline: 'none',
  },
  reviewContainer: {
    display: 'flex',
    flexDirection: 'column',
    gap: '10px',
  },
  reviewTitle: {
    color: '#aaa',
    fontSize: '12px',
    textTransform: 'uppercase',
  },
  explanationText: {
    color: '#ddd',
    fontSize: '14px',
    lineHeight: '1.4',
    marginBottom: '5px',
  },
  commandCode: {
    backgroundColor: '#111',
    padding: '8px',
    borderRadius: '4px',
    color: '#50fa7b',
    fontSize: '14px',
    wordBreak: 'break-all',
  },
  refineForm: {
    width: '100%',
    marginTop: '10px',
    boxSizing: 'border-box',
  },
  refineInput: {
    width: '100%',
    backgroundColor: '#1e1e1e',
    border: '1px solid #444',
    borderRadius: '4px',
    padding: '10px',
    paddingRight: '35px',
    color: 'white',
    fontSize: '13px',
    outline: 'none',
    boxSizing: 'border-box',
  },
  refineSubmitBtn: {
    position: 'absolute',
    right: '8px',
    top: '50%',
    transform: 'translateY(-50%)',
    background: 'none',
    border: 'none',
    color: '#666',
    cursor: 'pointer',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonGroup: {
    display: 'flex',
    justifyContent: 'flex-end',
    gap: '10px',
    marginTop: '5px',
  },
  executeButton: {
    backgroundColor: '#50fa7b',
    color: '#000',
    border: 'none',
    padding: '6px 12px',
    borderRadius: '4px',
    cursor: 'pointer',
    fontWeight: 'bold',
  },
  cancelButton: {
    backgroundColor: 'transparent',
    color: '#ff5555',
    border: '1px solid #ff5555',
    padding: '6px 12px',
    borderRadius: '4px',
    cursor: 'pointer',
  },
};

export default App;
