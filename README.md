# @ohos-rs/terminal

OpenHarmony terminal component that embeds [libghostty-vt](https://github.com/ghostty-org/ghostty) behind an `XComponent` surface.

The native addon is built entirely by Zig. This workspace consumes the adjacent
`../ohos-zig-binding` checkout for XComponent, Native Window, Native Drawing,
and IME wrappers. Zig builds wgpu-native and the official libghostty-vt source;
the HAR does not vendor prebuilt `.a` files.

Terminal behavior is sourced from the pinned official Ghostty commit in
`build.zig.zon`; the wrapper includes Ghostty's public headers and does not
maintain a second ABI. The OHOS renderer follows Ghostty's generic renderer
model—dirty viewport rows, immutable frame data, GPU cell/background buffers,
color-aware glyph atlas, and a dedicated render thread—on top of wgpu-native.

## Stack

```
example/ (entry HAP demo)
  └─ Terminal / TerminalController  (@ohos-rs/terminal HAR)
       └─ XComponent(libraryname = "terminal")
            └─ libterminal.so   zig build
                 ├─ zig-napi
                 ├─ ohos-zig-binding (XComponent / window / drawing / IME)
                 ├─ raw-window-handle
                 ├─ wgpu-native-zig  (builds wgpu-native)
                 └─ ghostty          (builds libghostty-vt)
```

The library does not start a shell. The example echoes keyboard input locally. A real app owns PTY/SSH and wires `controller.write()` / `controller.feed()`.

## Layout

- `src/`: Zig addon
- `package/`: reusable HAR (`Terminal`, `TerminalController`)
- `example/`: Stage-model **entry** HAP demo (`pages/Index`)

## Demo

`example/` is the HarmonyOS entry module. After `zig build dist`, open this repository in DevEco Studio and run the entry HAP.

The demo page hosts `Terminal` and a cooked local shell (same host split as arkit). Tap the surface to open the native IME. Typed bytes go `on_input` → demo shell → `feed()`. **Hello**, **Colors**, and **Clear** inject focused VT samples; **Stress** injects 1,200 long, colored, Unicode lines for soft-wrap and scrollback verification.

## Build

Requires Zig 0.16, an OpenHarmony NDK, and a network fetch of the git dependencies on the first build.

```bash
export OHOS_NDK_HOME=/path/to/ohos-sdk
./scripts/build-ohos.sh
```

`OHOS_NDK_HOME` is normalized to the SDK root by the build script. Passing the
`native/` child is also accepted.

`zig build` compiles `libterminal.so` by building the git dependencies. `zig build dist` writes the addon into `package/libs/<abi>/` and `example/libs/<abi>/` so the HAR and entry module can package it.
Native builds default to `ReleaseFast`; use `-Doptimize=Debug` explicitly when
debugging. Running the terminal performance demo with Debug-built Ghostty or
wgpu-native is not representative and can trip HarmonyOS main-thread watchdogs.

Useful flags:

- `-Dnative=false` — host tests only, do not build the OHOS addon

The first `zig build` fetches git archives and compiles wgpu-native (Rust/cargo) plus libghostty-vt. Later builds reuse the cache.

### Package the HAR

Install `ohpm-rs`, configure `OHOS_NDK_HOME`, then run:

```bash
./scripts/pack-ohpm.sh
```

The script builds and verifies `libterminal.so` for `arm64-v8a`,
`armeabi-v7a`, and `x86_64` before invoking `ohpm-rs prepublish` and
`ohpm-rs pack`. The resulting HAR is written to `dist/`. `package/README.md`
and `package/LICENSE` are relative symlinks to their repository-root files so
the published package always carries the canonical documentation and license.

## Runtime architecture

The terminal follows the same ownership split used by gpui-ghostty and
arkit_terminal:

1. ArkTS owns component lifecycle and the host I/O boundary. Typed input goes
   to the app through `on_input`; only host output is fed back to Ghostty.
   Hardware keys are encoded by Ghostty's own `GhosttyKeyEncoder`, synchronized
   from current terminal modes rather than a local escape-sequence table.
2. A chunked output worker owns libghostty-vt mutation and captures immutable
   viewport snapshots. `feed()` only enqueues bytes, so large PTY bursts never
   parse on ArkUI. Surface size and font density determine rows and columns;
   the grid is reflowed instead of stretching glyphs to preserve a fixed size.
3. The render worker exclusively owns wgpu, the retained `OHNativeWindow`, and
   swapchain presentation. Distinct graphemes are rasterized once into a
   persistent GPU atlas; backgrounds, cached glyph quads, and the cursor are
   submitted as GPU instances. There is no CPU-composited fullscreen bitmap.
   Frame publication is latest-wins so slow frames cannot replay stale states.
4. Renderer readiness means that a frame was successfully presented, not just
   that a device was created. Surface loss and validation errors remain visible
   through the ArkTS diagnostic overlay.

XComponent frame callbacks never wait for the terminal worker: if VT parsing is
currently mutating the grid, that display tick is skipped and the latest
immutable frame wins. Touch scrolling accumulates atomically and is applied on
the next available frame, preventing engine-lock contention from blocking the
ArkUI thread.

Surface and input callbacks only retain native resources or enqueue work. The
output worker performs VT parsing; an available frame tick applies pending
viewport movement and cursor timing. Both paths share the terminal-state lock,
while the render worker consumes immutable snapshots and never reads mutable
Ghostty state.

As in official Ghostty, font discovery and a glyph's first rasterization are
CPU/font-system operations. Once cached, terminal frame
composition and presentation are GPU-only; normal frames do not create or
upload a fullscreen CPU bitmap.

## Usage

```ts
import { Terminal, TerminalController } from '@ohos-rs/terminal';

@Entry
@Component
struct TerminalPage {
  private controller: TerminalController = new TerminalController();

  aboutToAppear(): void {
    this.controller.updateConfig({ fontSize: 16 });
    this.controller.setInputListener((data: string) => {
      this.driver.write(data);
    });
  }

  build() {
    Terminal({
      controller: this.controller,
      surfaceId: 'main-terminal',
      surfaceColor: '#0B0D10'
    })
  }
}
```

## Git dependencies

Declared in `build.zig.zon` and built by Zig:

- `openharmony-zig/zig-napi`
- `openharmony-zig/raw-window-handle`
- `openharmony-zig/wgpu_native_zig`
- `ghostty-org/ghostty` (`ghostty-vt-static` artifact)

`ohos-zig-binding` is a local workspace dependency until the new
`native_drawing` and `input_method` modules are published.

## LICENSE

[MIT](./LICENSE)
