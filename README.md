# マルチアカウントメールクライアント

作成日: 2026-10-20 / 状態: Phase 00Aの最小アプリ骨格

Tauri 2 + Vue 3 + TypeScript + Rust + SQLiteで、macOS / Windows / Ubuntu向けデスクトップメールクライアントを段階的に作ります。現在は最小アプリと設計・実行用資料がある段階で、メール機能やPhase 00の技術PoCは未実装です。

## 資料

- [設計書](docs/01-design.md): 責務、DB、同期、送信、OAuth2、検索、セキュリティ。
- [受け入れ基準・テスト計画](docs/02-acceptance-tests.md): 要件ID、障害試験、性能、リリース判定。
- [OS別CI・配布計画](docs/03-ci-release.md): PR、実機UI、資格情報、署名、更新。
- [根拠・技術判断](docs/04-sources-decisions.md): 公式資料、採用前の確認事項。
- [開発状況](docs/status.md): Phase・AC・実行証拠と未解決事項。
- [ADR-001](docs/adr/ADR-001-platform-toolchains.md): 対象OS、runner、ツールチェーン候補。
- [マスタープロンプト](prompts/00-master.md): Copilot Agentの初回チャットに渡す指示。
- `prompts/phase-00.md`〜`phase-08.md`: 各Phaseの実装指示。
- [.github/copilot-instructions.md](.github/copilot-instructions.md): リポジトリの常設指示。

## 開発環境

VS Codeでこのフォルダを開き、Dev Containers拡張から「Reopen in Container」を選べます。Dockerが利用できないWindowsホストでは、以下のネイティブ手順を使ってください。ツールチェーンは[固定ツールチェーン](docs/adr/ADR-001-platform-toolchains.md)に合わせます。

### Windows（Dockerなし）

1. [Node.js 26.13.1 x64](https://nodejs.org/dist/v26.13.1/node-v26.13.1-x64.msi)をインストールし、PowerShellで`npm install --global pnpm@12.14.0`を実行します。
2. [Rustup](https://www.rust-lang.org/tools/install)をインストールし、次を実行します。

   ```powershell
   rustup toolchain install 1.99.1 --profile minimal --component clippy --component rustfmt
   ```

3. [Visual Studio C++ Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/)で「Desktop development with C++」ワークロード（MSVC x64/x86 toolsとWindows SDK）を追加します。[WebView2 Runtime](https://developer.microsoft.com/microsoft-edge/webview2/)も必要です。
4. VS Codeを開き直し、PowerShellで以下を実行します。

   ```powershell
   .\scripts\setup-windows-dev.ps1
   ```

このスクリプトは固定版Node/pnpm/Rust、MSVC、WebView2を検査し、`pnpm install --frozen-lockfile`、`cargo fetch --locked`、フロントエンドbuild、Rust workspace testsを実行します。ツールやOSコンポーネントのグローバルインストールは行いません。版が違う場合や前提ツールが不足する場合は、依存を変更せず不足項目を表示して停止します。

開発アプリは`pnpm run tauri dev`で起動します。

### Dev Container

Dockerが利用できる環境では、Dev Containers拡張から「Reopen in Container」を選びます。コンテナにはLinux向けTauri依存と固定版ツールチェーンが含まれます。

1回の依頼で1つの縦切り機能を実装し、受け入れ基準・テスト・制限を確認します。Phase全体を一度に実装せず、未実行の試験を合格にしないでください。

## 到達点

| Phase | 到達点 | 公開範囲 |
|---|---|---|
| 00 | 技術検証、脅威モデル、CI骨格 | 開発用 |
| 01 | 型付きIPC、DB、テストデータUI | 開発用 |
| 02 | 複数アカウントIMAP閲覧、安全な本文表示 | 閲覧MVP。一般IMAP・アプリパスワード対応先 |
| 03 | 差分同期、切断復旧、キャッシュ閲覧 | 読み取り専用ベータ |
| 04 | 既読、フラグ、移動、ゴミ箱、オフライン操作 | 書き込みベータ |
| 05 | SMTP、下書き、返信・転送、送信トレイ | 送受信ベータ |
| 06 | Google / Microsoft OAuth2 | 対応プロバイダ拡張 |
| 07 | 日本語全文検索、容量管理、復旧 | 機能完成候補 |
| 08 | 3OS実機QA、署名、更新、配布 | 安定版 |

Google / Microsoftを最初の利用者に必須とする場合はPhase 06の認証部分をPhase 02の前へ移動する。パスワード認証を無理に有効化したり、MFAを解除したりしない。

初版ではPOP3、カレンダー、連絡先同期、ルールエンジン、S/MIME・OpenPGP、共有メールボックス高度機能、サーバ管理を対象外とする。暗号化メールは未対応と明示する。
