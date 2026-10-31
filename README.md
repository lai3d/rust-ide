# RustIDE

A native macOS IDE for Rust — Swift 6, SwiftUI + AppKit, SwiftPM.

> **Status: early.** Forked from [GoIDE](https://github.com/lai3d/golang-ide)'s LSP/DAP architecture
> and being ported to the Rust toolchain. See [ROADMAP.md](ROADMAP.md).

## Toolchain

- **rust-analyzer** — language server (`rustup component add rust-analyzer`)
- **cargo** — build / run / test / check / clippy / fmt
- **lldb-dap** — debugger (ships with Xcode: `xcrun -f lldb-dap`)

## Build & run

```sh
swift build
.build/debug/RustIDE Examples/hello   # opens a folder
swift test
scripts/bundle.sh               # build/RustIDE.app + build/RustIDE.zip (ad-hoc signed)
```

Requires macOS 14+ and Swift 6.

## License

MIT
