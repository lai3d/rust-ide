# RustIDE

A native macOS IDE for Rust: Swift 6, SwiftUI + AppKit, SwiftPM. It's built on
[GoIDE](https://github.com/lai3d/golang-ide)'s LSP/DAP editor shell, with the
language layer rebuilt around rust-analyzer, Cargo and LLDB.

## Features

- **rust-analyzer**: diagnostics (with `cargo check` on save), completion with
  snippets, hover, signature help, go to definition / implementation / type definition,
  references, rename, assists and quick fixes, inlay hints, semantic highlighting,
  call hierarchy, folding, outline, workspace symbols, rustfmt on save
- **Editor**: tabs, a hand-written Rust lexer (raw strings, lifetimes, nested comments),
  line numbers, breadcrumbs, auto-closing pairs, space indentation, Rust snippets,
  find / replace in project, Open Quickly (⌘P)
- **Cargo**: Run (⌘R) with run configurations from `cargo metadata` (binaries and
  examples, args, env, features, release), Build (⌘B), Check (⇧⌘B), Clippy, fmt, doc,
  clean, update; `src/main.rs:12:5` locations in the output are clickable
- **Tests**: `cargo test` results per test (unit, integration, doc-tests), ▶ / ✓ / ✗ in
  the gutter, run the test at the caret, failure output
- **Debugger** (lldb-dap): breakpoints (conditional too), step, call stack, variables
  shown with rustc's formatters (`Vec`, `String`, `Option`…), watches, hover to evaluate;
  debug a run configuration or the `#[test]` at the caret
- **Git**: status badges, change bars, inline blame, diff against HEAD, stage and commit
- Integrated terminal, multiple windows, session restore

## Requirements

- macOS 14+
- A Rust toolchain from [rustup](https://rustup.rs), plus rust-analyzer:
  `rustup component add rust-analyzer`
- For debugging: Xcode or the Command Line Tools (`lldb-dap`, found via `xcrun`).
  If macOS asks for permission each time you debug, enable developer mode:
  `sudo DevToolsSecurity -enable`

Tool paths can be overridden in Settings ▸ Tools.

## Build & run

```sh
swift build
.build/debug/RustIDE Examples/hello   # opens a folder
swift test
scripts/bundle.sh                     # build/RustIDE.app + build/RustIDE.zip (ad-hoc signed)
```

Releases are built by GitHub Actions when a `v*` tag is pushed. See [ROADMAP.md](ROADMAP.md).

## License

MIT
