import {
  CellMetrics,
  cloneTerminalConfig,
  CursorPosition,
  DEFAULT_TERMINAL_CONFIG,
  TerminalAttachmentListener,
  TerminalConfig,
  TerminalConfigPatch,
  TerminalInputListener,
  TerminalSize,
  TerminalSizeListener
} from './TerminalTypes';

interface TerminalNativeBridge {
  writeInput: (data: string) => void;
  feedOutput: (data: string) => void;
  drainPendingInput: () => string;
  getScreenContent: () => string;
  getCursorPosition: () => CursorPosition;
  getTerminalSize: () => TerminalSize;
  getCellMetrics: () => CellMetrics;
  setSurfaceSize: (width: number, height: number) => void;
  scrollView: (delta: number) => void;
  resetScroll: () => void;
  getScrollbackSize: () => number;
  setConfig: (config: TerminalConfig) => void;
  setDensity: (density: number) => void;
  isRendererReady: () => boolean;
  getRendererError: () => string;
  showKeyboard: () => void;
}

export class TerminalController {
  private native: TerminalNativeBridge | null = null;
  private config: TerminalConfig = cloneTerminalConfig(DEFAULT_TERMINAL_CONFIG);
  private inputListener: TerminalInputListener | null = null;
  private attachmentListener: TerminalAttachmentListener | null = null;
  private sizeListener: TerminalSizeListener | null = null;
  private inputPollTimer: number = -1;
  private lastReportedSize: TerminalSize = { cols: 0, rows: 0 };

  bindNative(native: Object, density: number): void {
    this.native = native as TerminalNativeBridge;
    this.native.setDensity(density);
    this.applyConfig();
    this.startInputPolling();
    this.notifyAttachmentChanged(true);
  }

  unbindNative(): void {
    this.stopInputPolling();
    this.native = null;
    this.lastReportedSize = { cols: 0, rows: 0 };
    this.notifyAttachmentChanged(false);
  }

  isAttached(): boolean {
    return this.native !== null;
  }

  setConfig(config: TerminalConfig): void {
    this.config = cloneTerminalConfig(config);
    this.applyConfig();
  }

  updateConfig(patch: TerminalConfigPatch): void {
    const nextConfig = cloneTerminalConfig(this.config);
    if (patch.fontSize !== undefined) {
      nextConfig.fontSize = patch.fontSize;
    }
    if (patch.scrollbackLines !== undefined) {
      nextConfig.scrollbackLines = patch.scrollbackLines;
    }
    if (patch.bgColor !== undefined) {
      nextConfig.bgColor = patch.bgColor;
    }
    if (patch.fgColor !== undefined) {
      nextConfig.fgColor = patch.fgColor;
    }
    if (patch.cursorStyle !== undefined) {
      nextConfig.cursorStyle = patch.cursorStyle;
    }
    if (patch.cursorBlink !== undefined) {
      nextConfig.cursorBlink = patch.cursorBlink;
    }
    this.setConfig(nextConfig);
  }

  getConfig(): TerminalConfig {
    return cloneTerminalConfig(this.config);
  }

  setInputListener(listener: TerminalInputListener | null): void {
    this.inputListener = listener;
    this.startInputPolling();
  }

  setAttachmentListener(listener: TerminalAttachmentListener | null): void {
    this.attachmentListener = listener;
    this.notifyAttachmentChanged(this.isAttached());
  }

  setSizeListener(listener: TerminalSizeListener | null): void {
    this.sizeListener = listener;
    if (listener) {
      this.notifySizeChanged();
    }
  }

  showKeyboard(): void {
    this.native?.showKeyboard();
  }

  write(data: string): void {
    if (!this.native || data.length === 0) {
      return;
    }
    this.native.writeInput(data);
  }

  feed(data: string): void {
    if (!this.native || data.length === 0) {
      return;
    }
    this.native.feedOutput(data);
  }

  setSurfaceSize(width: number, height: number): void {
    if (!this.native) {
      return;
    }
    this.native.setSurfaceSize(width, height);
    this.notifySizeChanged();
  }

  scrollView(delta: number): void {
    this.native?.scrollView(delta);
  }

  resetScroll(): void {
    this.native?.resetScroll();
  }

  getScrollbackSize(): number {
    return this.native ? this.native.getScrollbackSize() : 0;
  }

  getScreenContent(): string {
    return this.native ? this.native.getScreenContent() : '';
  }

  getCursorPosition(): CursorPosition {
    return this.native ? this.native.getCursorPosition() : { row: 0, col: 0 };
  }

  getTerminalSize(): TerminalSize {
    return this.native ? this.native.getTerminalSize() : { cols: 0, rows: 0 };
  }

  getCellMetrics(): CellMetrics {
    if (!this.native) {
      return { width: 0, height: 0 };
    }
    return this.native.getCellMetrics();
  }

  isRendererReady(): boolean {
    return this.native ? this.native.isRendererReady() : false;
  }

  getRendererError(): string {
    return this.native ? this.native.getRendererError() : '';
  }

  private applyConfig(): void {
    this.native?.setConfig(this.config);
  }

  private startInputPolling(): void {
    if (!this.native || this.inputPollTimer >= 0) {
      return;
    }
    this.inputPollTimer = setInterval(() => {
      if (!this.native) {
        return;
      }
      if (!this.inputListener) {
        return;
      }
      const pending = this.native.drainPendingInput();
      if (pending.length > 0) {
        this.inputListener(pending);
      }
    }, 16) as number;
  }

  private stopInputPolling(): void {
    if (this.inputPollTimer < 0) {
      return;
    }
    clearInterval(this.inputPollTimer);
    this.inputPollTimer = -1;
  }

  private notifyAttachmentChanged(attached: boolean): void {
    this.attachmentListener?.(attached);
  }

  private notifySizeChanged(): void {
    if (!this.native || !this.sizeListener) {
      return;
    }
    const size = this.native.getTerminalSize();
    if (size.cols <= 0 || size.rows <= 0) {
      return;
    }
    if (size.cols === this.lastReportedSize.cols && size.rows === this.lastReportedSize.rows) {
      return;
    }
    this.lastReportedSize = { cols: size.cols, rows: size.rows };
    this.sizeListener(this.lastReportedSize);
  }
}
