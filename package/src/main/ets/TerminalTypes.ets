export interface CursorPosition {
  row: number;
  col: number;
}

export interface CellMetrics {
  width: number;
  height: number;
}

export interface TerminalSize {
  cols: number;
  rows: number;
}

export type TerminalInputListener = (data: string) => void;
export type TerminalAttachmentListener = (attached: boolean) => void;
export type TerminalSizeListener = (size: TerminalSize) => void;

export interface TerminalConfig {
  fontSize: number;
  scrollbackLines: number;
  bgColor: number;
  fgColor: number;
  cursorStyle: number;
  cursorBlink: boolean;
}

export interface TerminalConfigPatch {
  fontSize?: number;
  scrollbackLines?: number;
  bgColor?: number;
  fgColor?: number;
  cursorStyle?: number;
  cursorBlink?: boolean;
}

export const DEFAULT_TERMINAL_CONFIG: TerminalConfig = {
  fontSize: 14,
  scrollbackLines: 10000,
  bgColor: 0xFF0B1220,
  fgColor: 0xFFE2E8F0,
  cursorStyle: 0,
  cursorBlink: true
};

export function cloneTerminalConfig(config: TerminalConfig): TerminalConfig {
  return {
    fontSize: config.fontSize,
    scrollbackLines: config.scrollbackLines,
    bgColor: config.bgColor,
    fgColor: config.fgColor,
    cursorStyle: config.cursorStyle,
    cursorBlink: config.cursorBlink
  };
}
