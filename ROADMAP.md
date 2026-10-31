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
| 1.4 | ⬜ Cargo tests | `cargo test` runner, gutter ▶ / ✓ / ✗ per `#[test]`, run at cursor / module / all | 0.7h |
| 1.5 | ⬜ Debugger (lldb-dap) | Replace Delve: launch the built binary / test binary under `xcrun lldb-dap`, Rust variable formatting | 1–1.5h |
| 1.6 | ✅ Run configurations | Bins / examples from `cargo metadata` (refreshed when Cargo.toml changes), args, env, features, release profile | 0.5h |
| 1.7 | ⬜ Snippets & settings | Rust snippets (`fn`, `test`, `impl`, `match`, …); cargo / rust-analyzer / lldb-dap path overrides | 0.4h |
| 1.8 | ⬜ CI & release | Rust toolchain in GitHub Actions, tagged `RustIDE-vX.Y.Z.zip`, app icon, IDE Toolbox catalog entry | 0.5h |

## Phase 2 — Rust-specific features

| # | Item | Notes | Est. |
|---|---|---|---|
| 2.1 | ⬜ Clippy & fmt | Clippy as check command, rustfmt on save, `rustfmt.toml` respected | 0.3h |
| 2.2 | ⬜ Expand macro | rust-analyzer `expandMacro` at the caret, shown in a read-only tab | 0.3h |
| 2.3 | ⬜ Cargo.toml tools | Dependencies view from `cargo metadata`, `cargo update`, feature toggles | 0.6h |
| 2.4 | ⬜ Runnables | rust-analyzer `experimental/runnables`: ▶ on `main`, tests, benches, doctests | 0.5h |
| 2.5 | ⬜ Coverage | `cargo llvm-cov` if installed | 0.5h |

**User must do manually** (duration outside Claude's control): Apple Developer Program enrollment,
Developer ID certificate and notarization credentials, only to ship signed builds to others.
