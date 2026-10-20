# ADR-001: 対象OS・runner・初期ツールチェーン

- 状態: Phase 00Aの候補を採用。GitHub CIと最低対応OSの実機検証後に確定する
- 決定日: 2026-10-20

## 背景

初版はWindows 11 x64、Ubuntu 24.04 LTS x64、macOS 14以降のarm64 / x64を候補とする。Tauriのネイティブ依存とWebViewはOSごとに異なるため、クロスコンパイルだけで対応可とは判定しない。

## 決定

### 製品サポート候補

| OS / arch | 最低版候補 | WebView | 実機候補 |
|---|---|---|---|
| Windows x64 | Windows 11 | WebView2 Evergreen | Windows 11 x64のIntel / AMDノートPC |
| Ubuntu x64 | Ubuntu 24.04 LTS | WebKitGTK 4.1 | Ubuntu 24.04 x64をクリーンインストールしたIntel / AMDノートPC |
| macOS arm64 | macOS 14 | WKWebView | Apple Silicon MacBook Air (M1以降) |
| macOS x64 | macOS 14 | WKWebView | Intel Mac mini (2018)またはmacOS 14対応Intel MacBook Pro |

上記は実機の合格証跡ではなく、調達・借用する試験候補。実機でOS更新、起動、WebView、SecretStore、IME、インストールを検証してから最低版を確定する。Windows ARM64、Linux ARM64、他Linuxディストリビューションは初版の製品対象外。

### CI runner候補

| 検証対象 | GitHub-hosted runner |
|---|---|
| Ubuntu x64 | `ubuntu-24.04` |
| Windows x64 | `windows-2025` |
| macOS arm64 | `macos-14` |
| macOS x64 | `macos-15-intel` |

公開GitHub-hosted runnerの公式一覧でラベルとarchを確認した（2026-10-20）。private repositoryでの利用可否・料金はリポジトリのプランで別途確認する。runnerの新しいOSは最低対応OSの実機検証を代替しない。

### 固定ツールチェーン

| 項目 | 固定値 |
|---|---|
| Node.js | 24.22.0 (LTS) |
| pnpm | 12.14.0 |
| Rust | 1.99.1、`clippy` / `rustfmt` component |
| Tauri CLI | 2.12.3 |
| Tauri JS API | 2.12.4 |
| Tauri Rust crate / build crate | 2.12.4 / 2.7.3 (`Cargo.lock`) |
| Vue | 3.5.44 |
| TypeScript | 6.0.3、strict |
| Vite | 8.3.4 |
| pnpm lock | `pnpm-lock.yaml`、frozen install |
| Cargo lock | workspace rootの`Cargo.lock`、`--locked` |

バージョンは公式配布情報とregistryで確認した時点の固定値。Tauri 1の設定・APIは使わない。

開発環境はNode公式Debian Bookwormイメージのdigest固定Dev Containerとし、Linux向けTauri依存、Xvfb、D-Bus、Rust toolchainを含める。Docker Desktop上ではlinux/arm64で動作するが、これはLinux arm64の製品サポートを意味しない。

## 選択肢

- OS標準の最新node/rustをそのまま使う: 再現性が低いため不採用。
- 1つのLinux runnerから全OSへcross-compile: WebView・OS依存build・実機起動を検証できないため不採用。
- macOSを単一archに限定: 初期設計のarm64 / x64要件を満たさないため不採用。

## 結果と制限

- `native.yml`は4 runner候補でformat、Rust test/clippy、frontend build、native build、smoke launch/exitを実行する。
- Linux CIはWebKitGTK 4.1依存を導入する。Windows runnerのWebView2 / MSVC、macOS runnerのXcode提供環境はGitHub-hosted imageに依存する。
- CI workflowはこの作業環境から実行できないため、4 runnerの実行結果は未確認。
- Tauri起動smoke testは`smoke-test` Cargo featureでのみ自動終了処理を有効にする。通常buildにはfeatureを含めない。
- 署名、公証、installer、最低OSの実機確認は本ADRの対象外。

## 再評価条件

runnerラベルの廃止、OS/WebViewのサポート終了、Rust/Node/Tauriの互換性問題、または最低OS実機試験の失敗があれば更新する。

## 根拠

- [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/)
- [GitHub-hosted runners reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Tauri configuration reference](https://v2.tauri.app/reference/config/)
- [Node.js release index](https://nodejs.org/dist/index.json)
- [Rust stable channel manifest](https://static.rust-lang.org/dist/channel-rust-stable.toml)
