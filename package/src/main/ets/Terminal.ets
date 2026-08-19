import { display } from '@kit.ArkUI';
import { TerminalController } from './TerminalController';
import { DEFAULT_TERMINAL_CONFIG } from './TerminalTypes';

const NATIVE_LIBRARY = 'terminal';

@Component
export struct Terminal {
  controller: TerminalController = new TerminalController();
  surfaceId: string = 'terminalSurface';
  surfaceColor: string = '#0B1220';

  private readyPollTimer: number = -1;
  private density: number = 0;

  @State private appliedFontSize: number = DEFAULT_TERMINAL_CONFIG.fontSize;
  @State private rendererStatus: string = 'Initializing native renderer…';
  @State private showRendererStatus: boolean = true;

  aboutToAppear(): void {
    this.appliedFontSize = this.controller.getConfig().fontSize;
    try {
      this.density = display.getDefaultDisplaySync().densityPixels;
    } catch (err) {
      this.rendererStatus = `Display density unavailable: ${JSON.stringify(err)}`;
      this.showRendererStatus = true;
    }
  }

  aboutToDisappear(): void {
    this.stopReadyPolling();
  }

  build() {
    Stack() {
      XComponent({
        id: this.surfaceId,
        type: XComponentType.SURFACE,
        libraryname: NATIVE_LIBRARY
      })
        .onLoad((nativeContext?: Object) => {
          if (!nativeContext) {
            this.rendererStatus = 'Native terminal module did not load.';
            this.showRendererStatus = true;
            return;
          }
          if (this.density <= 0) {
            return;
          }
          this.controller.bindNative(nativeContext, this.density);
          this.appliedFontSize = this.controller.getConfig().fontSize;
          this.refreshRendererState();
          this.startReadyPolling();
        })
        .onDestroy(() => {
          this.stopReadyPolling();
          this.controller.unbindNative();
        })
        .onAreaChange((_oldValue: Area, newValue: Area) => {
          const width = Number(newValue.width ?? 0);
          const height = Number(newValue.height ?? 0);
          if (this.density > 0 && Number.isFinite(width) && Number.isFinite(height)) {
            this.controller.setSurfaceSize(width * this.density, height * this.density);
          }
        })
        .focusable(true)
        .focusOnTouch(true)
        .width('100%')
        .height('100%')
        .backgroundColor(this.surfaceColor)

      if (this.showRendererStatus) {
        Text(this.rendererStatus)
          .fontSize(this.appliedFontSize)
          .fontColor('#E2E8F0')
          .fontFamily('monospace')
          .padding(12)
          .width('100%')
          .height('100%')
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.surfaceColor)
  }

  private startReadyPolling(): void {
    if (this.readyPollTimer >= 0) {
      return;
    }
    this.readyPollTimer = setInterval(() => {
      this.refreshRendererState();
    }, 250) as number;
  }

  private stopReadyPolling(): void {
    if (this.readyPollTimer < 0) {
      return;
    }
    clearInterval(this.readyPollTimer);
    this.readyPollTimer = -1;
  }

  private refreshRendererState(): void {
    const ready = this.controller.isRendererReady();
    this.showRendererStatus = !ready;
    if (ready) {
      this.rendererStatus = '';
      return;
    }
    const error = this.controller.getRendererError();
    this.rendererStatus = error.length > 0 ? `Renderer error: ${error}` : 'Initializing native renderer…';
  }
}
