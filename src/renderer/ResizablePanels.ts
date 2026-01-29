// Wrapper to handle naming differences in react-resizable-panels
// The library exports 'Group' and 'Separator' instead of 'PanelGroup' and 'PanelResizeHandle'
import { Group, Panel as RPPanel, Separator } from 'react-resizable-panels';

export const PanelGroup = Group;
export const Panel = RPPanel;
export const PanelResizeHandle = Separator;
