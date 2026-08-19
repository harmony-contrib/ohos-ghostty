import { Terminal, TerminalController } from '@ohos-rs/terminal';

class LocalShell {
  cols: number;
  rows: number;
  private line: string = '';
  private pending: string = '';

  constructor(cols: number, rows: number) {
    this.cols = cols;
    this.rows = rows;
  }

  reset(): void {
    this.line = '';
    this.pending = '';
  }

  banner(): string {
    let out = '\x1b[2J\x1b[H\x1b[?25h';
    out += '\x1b[1;36mohos-rs/terminal\x1b[0m\r\n';
    out += '\x1b[2mhelp  echo  clear  uname  info\x1b[0m\r\n';
    for (let i = 1; i <= 12; i++) {
      out += `history ${i.toString().padStart(2, '0')}\r\n`;
    }
    out += '\x1b[33mready\x1b[0m\r\n';
    out += this.prompt();
    return out;
  }

  prompt(): string {
    return '\x1b[32m$\x1b[0m ';
  }

  input(data: string): string {
    this.pending += data;
    let out = '';
    while (this.pending.length > 0) {
      const code = this.pending.charCodeAt(0);
      if (code === 0x1b) {
        const skipped = this.skipEscape(this.pending);
        if (skipped === 0) {
          break;
        }
        this.pending = this.pending.substring(skipped);
        continue;
      }
      this.pending = this.pending.substring(1);
      if (code === 0x0d || code === 0x0a) {
        out += '\r\n';
        const cmd = this.line.trim();
        this.line = '';
        out += this.exec(cmd);
        out += this.prompt();
        continue;
      }
      if (code === 0x7f || code === 0x08) {
        if (this.line.length > 0) {
          this.line = this.line.substring(0, this.line.length - 1);
          out += '\x08\x1b[P';
        }
        continue;
      }
      if (code === 0x03) {
        this.line = '';
        out += '^C\r\n';
        out += this.prompt();
        continue;
      }
      if (code === 0x0c) {
        out += '\x1b[2J\x1b[H';
        out += this.prompt();
        out += this.line;
        continue;
      }
      if (code >= 0x20) {
        const ch = String.fromCharCode(code);
        this.line += ch;
        out += ch;
      }
    }
    return out;
  }

  private exec(cmd: string): string {
    if (cmd.length === 0) {
      return '';
    }
    const parts = cmd.split(/\s+/);
    const head = parts[0];
    const rest = parts.slice(1).join(' ');
    switch (head) {
      case 'help':
      case '?':
        return 'help  echo  clear  uname  info\r\n';
      case 'echo':
        return `${rest}\r\n`;
      case 'clear':
        return '\x1b[2J\x1b[H';
      case 'uname':
        return 'ohos-rs-local\r\n';
      case 'info':
        return `cols=${this.cols} rows=${this.rows}\r\n`;
      default:
        return `not found: ${head}\r\n`;
    }
  }

  private skipEscape(buf: string): number {
    if (buf.length === 0 || buf.charCodeAt(0) !== 0x1b) {
      return 0;
    }
    if (buf.length === 1) {
      return 0;
    }
    if (buf.charAt(1) === 'O') {
      return buf.length >= 3 ? 3 : 0;
    }
    if (buf.charAt(1) === '[') {
      for (let i = 2; i < buf.length; i++) {
        const code = buf.charCodeAt(i);
        if (code >= 0x40 && code <= 0x7e) {
          return i + 1;
        }
      }
      return 0;
    }
    return 2;
  }
}

const DEMO_COLORS =
  '\x1b[0m' +
  '\x1b[30mblk\x1b[0m \x1b[31mred\x1b[0m \x1b[32mgrn\x1b[0m \x1b[33mylw\x1b[0m ' +
  '\x1b[34mblu\x1b[0m \x1b[35mmag\x1b[0m \x1b[36mcyn\x1b[0m \x1b[37mwht\x1b[0m\r\n' +
  '\x1b[1mbold\x1b[0m \x1b[3mitalic\x1b[0m \x1b[2mfaint\x1b[0m ' +
  '\x1b[7minverse\x1b[0m \x1b[9mstrike\x1b[0m \x1b[53moverline\x1b[0m\r\n' +
  '\x1b[4msingle\x1b[0m \x1b[4:2mdouble\x1b[0m \x1b[4:3;58;2;255;100;80mcurly\x1b[0m ' +
  '\x1b[4:4mdotted\x1b[0m \x1b[4:5mdashed\x1b[0m  color emoji: 🙂 🚀\r\n';

function stressTranscript(lineCount: number): string {
  const chunks: string[] = ['\r\n\x1b[1;36m— long output / wrap / Unicode stress —\x1b[0m\r\n'];
  for (let index = 0; index < lineCount; index++) {
    const color = 31 + index % 6;
    chunks.push(
      `\x1b[${color}m${index.toString().padStart(4, '0')}\x1b[0m ` +
      '0123456789 abcdefghijklmnopqrstuvwxyz ' +
      'soft-wrap-without-manual-column-break 中文 é 🙂 terminal-scrollback-validation\r\n'
    );
  }
  chunks.push('\x1b[1;32m— stress output complete; swipe to inspect history —\x1b[0m\r\n');
  return chunks.join('');
}

@Entry
@Component
struct Index {
  private controller: TerminalController = new TerminalController();
  private shell: LocalShell = new LocalShell(40, 24);

  aboutToAppear(): void {
    this.controller.updateConfig({ fontSize: 16, scrollbackLines: 5000, cursorBlink: true });
    this.controller.setSizeListener((size) => {
      this.shell.cols = size.cols;
      this.shell.rows = size.rows;
    });
    this.controller.setInputListener((data: string) => {
      const output = this.shell.input(data);
      if (output.length > 0) {
        this.controller.feed(output);
      }
    });
    this.controller.setAttachmentListener((attached: boolean) => {
      if (attached) {
        this.shell.reset();
        this.controller.feed(this.shell.banner());
      }
    });
  }

  build() {
    Column() {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('Terminal demo · tap to type')
            .fontSize(16)
            .fontColor('#E2E8F0')
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
            .maxLines(1)
          Button('Keyboard')
            .height(32)
            .fontSize(12)
            .onClick(() => {
              this.controller.showKeyboard();
            })
        }
        .width('100%')

        Row({ space: 8 }) {
          Button('Hello')
            .height(32)
            .fontSize(12)
            .layoutWeight(1)
            .onClick(() => {
              const output = this.shell.input('echo hello from HarmonyOS\r');
              if (output.length > 0) {
                this.controller.feed(output);
              }
            })
          Button('Colors')
            .height(32)
            .fontSize(12)
            .layoutWeight(1)
            .onClick(() => {
              this.controller.feed('\r\n');
              this.controller.feed(DEMO_COLORS);
              this.controller.feed(this.shell.prompt());
            })
          Button('Clear')
            .height(32)
            .fontSize(12)
            .layoutWeight(1)
            .onClick(() => {
              this.controller.feed('\x1b[2J\x1b[H\x1b[?25h');
                this.controller.feed(this.shell.banner());
            })
          Button('Stress')
            .height(32)
            .fontSize(12)
            .layoutWeight(1)
            .onClick(() => {
              this.controller.feed(stressTranscript(1200));
              this.controller.feed(this.shell.prompt());
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor('#11161D')

      Terminal({
        controller: this.controller,
        surfaceId: 'example-terminal',
        surfaceColor: '#0B1220'
      })
        .width('100%')
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B1220')
  }
}
