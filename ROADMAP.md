# RustIDE Roadmap

Status: ✅ done · 🚧 in progress · ⬜ planned

Estimates are Claude Code session time.

Forked from GoIDE, so the editor shell (tabs, gutter, folding, search/replace, Git, terminal,
LSP + DAP clients, multi-window, session restore) already exists. The work is porting the
language-specific layer.

## Phase 0 — Fork

| # | Item | Notes | Est. |
|---|---|---|---|
| 0.1 | ✅ Fork GoIDE → RustIDE | Rename targets, bundle ID `io.github.lai3d.rustide`, Cargo example | 0.1h |

## Phase 1 — Port to the Rust toolchain

| # | Item | Notes | Est. |
|---|---|---|---|
| 1.1 | ✅ rust-analyzer | Replaces gopls: settings, `experimental/serverStatus` ready state, rustfmt formatting, `target/` ignored; LSP tests on a shared Cargo-crate harness | 0.6h |
| 1.2 | ✅ Rust highlighter | Hand-written lexer for Rust (lifetimes, raw strings, attributes, macros, nested block comments) under semantic tokens | 0.5h |
| 1.3 | ✅ Cargo build / run / check | Cargo menu: run, build, check (⇧⌘B), clippy, fmt, doc, clean, dependencies; clickable `file.rs:L:C` in Output (rust-analyzer already feeds check diagnostics to Problems) | 0.6h |
| 1.4 | ✅ Cargo tests | libtest output parser (suites, ok / FAILED / ignored, captured failure output); `#[test]` finder with module paths; gutter ▶ / ✓ / ✗; run at caret (`-- path --exact` in the right `--lib` / `--bin` / `--test` target), package, all | 0.7h |
| 1.5 | ✅ Debugger (lldb-dap) | DAP over stdio to `xcrun lldb-dap`; builds with `--message-format=json-render-diagnostics` and debugs the artifact (run configurations or one `#[test]`); rustc's LLDB formatters for Vec / String / Option; verified on CI (needs macOS developer mode) | 1–1.5h |
| 1.6 | ✅ Run configurations | Bins / examples from `cargo metadata` (refreshed when Cargo.toml changes), args, env, features, release profile | 0.5h |
| 1.7 | ✅ Snippets & settings | 18 Rust snippets that complement rust-analyzer's own; space indentation (Tab, Return, ⌘] / ⌘[, electric `}`) at the tab-width setting; cargo / rust-analyzer / lldb-dap path overrides | 0.4h |
| 1.8 | ✅ CI & release | ✅ CI installs rustup + rust-analyzer and enables debugging; ✅ release workflow (`v*` tag → RustIDE.zip); ✅ app icon; ✅ folder-argument window fix; ✅ v0.1.0 released; ✅ in IDE Toolbox v0.4.0 | 0.5h |

## Phase 2 — Rust-specific features

| # | Item | Notes | Est. |
|---|---|---|---|
| 2.1 | ✅ Clippy & fmt | Settings ▸ Check on save (cargo check / clippy) and Cargo ▸ Clippy on Save, pushed live via didChangeConfiguration; rustfmt on save respects `rustfmt.toml` | 0.3h |
| 2.2 | ✅ Expand macro | Navigate ▸ Expand Macro (⌃⌥⌘M, also in the editor menu): `rust-analyzer/expandMacro` into a read-only, highlighted tab kept away from rust-analyzer. Function-like macros only: rust-analyzer 1.95 returns nothing for derives | 0.3h |
| 2.3 | ✅ Cargo.toml tools | Sidebar ▸ Cargo: per-package features (toggles go to rust-analyzer `cargo.features` and build / check / clippy / test as `--features pkg/feat`, saved per project) and dependencies by kind with Cargo.lock versions; add (`cargo add`), remove, update, docs.rs / crates.io | 0.6h |
| 2.4 | ✅ Runnables | rust-analyzer `experimental/runnables` in the gutter: ▶ on `main`, doctests and benches, ⏩ on test modules (next to the local #[test] markers); tests run in the Tests panel, the rest in Output | 0.5h |
| 2.5 | ⬜ Coverage | `cargo llvm-cov` if installed | 0.5h |

**User must do manually** (duration outside Claude's control): Apple Developer Program enrollment,
Developer ID certificate and notarization credentials, only to ship signed builds to others.
