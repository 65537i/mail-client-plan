# OS別CIと配布計画

## 1. ワークフロー構成

| Workflow | 起動 | 必須処理 |
|---|---|---|
| verify | PR / main | format、lint、typecheck、unit、UI component、依存監査、secret scan、設定検査 |
| native | PR / 手動実行は4 runner matrix。mainへのpushはUbuntuのみ。`docs/status.md`のみの変更では起動しない | Rust check/test、Tauri build、一時DB integration、capability契約試験 |
| protocol | PR / main、Ubuntu | pinned IMAP/SMTP fixtureサーバ、TLS、fault injection、オフライン収束 |
| desktop | PR / main、3OS | 実WebView E2E、HTML攻撃、IPC拒否、再起動。GUI環境が必要 |
| compatibility | nightly / release | OS最低版/現行版、macOS 2 arch、WebView差異、長時間同期、fuzz corpus |
| release | protected tag + environment | 承認済みcommitの再ビルド、署名、公証、SBOM、hash、更新署名、draft release |

初期runner候補: ubuntu-24.04 / windows-2022 / macOSは利用可能なarm64・x64ラベルをPhase 00で検証して固定する。runnerラベルや内蔵OSは変更されうるため、対応する実機の最低OS試験を別に持つ。latestを製品の最低動作OSの証明にしない。

Linux: Tauri公式prerequisitesに従うWebKitGTK 4.1等を固定された環境に導入し、GUI試験はXvfb + D-Bus + Secret Serviceのセッションを準備する。コンテナfixtureはUbuntuで動かし、他OSはネイティブのscripted protocol serverを使う。全OSでDocker利用可能と仮定しない。

Windows: MSVC toolchain、WebView2、必要SDK。WebDriverを外部利用する場合はEdge/driver互換版を確認する。Credential Managerは実ユーザー環境も確認する。macOS: Xcode toolchain、deployment target、arm64/x64、Keychain・署名権限を分離する。

## 2. 検証コマンドの契約

Phase 01で以下のpackage scriptsを用意する。これは計画上の名称であり、現時点で実装済みではない。

```text
pnpm install --frozen-lockfile
pnpm lint
pnpm typecheck
pnpm test:unit
pnpm test:ui
pnpm test:e2e:desktop
pnpm tauri build
cargo fmt --all --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cargo audit
cargo deny check
```

Rust workspaceがsrc-tauri配下ならmanifest-pathまたはcwdを明示する。CIで未作成scriptを成功stubにしない。監査ツール本体も版固定する。OS別feature組み合わせを試験し、無効なall-featuresで形式的に失敗させない。

## 3. WebView E2Eの注意点

2026-10-20確認時の英語版Tauri公式資料は、WebdriverIO + @wdio/tauri-serviceの組み込みサーバ方式で3OS対応を案内している。一方、tauri-driverを直接使う従来方式はmacOS非対応。古い翻訳や一般論だけでmacOS E2Eを省略しない。[公式WebDriver概要](https://v2.tauri.app/develop/tests/webdriver/) / [manual setup](https://v2.tauri.app/develop/tests/webdriver/manual-setup/)

Phase 00で固定版によるPoCを行い、以下を証明する。

1. 各OSでrelease相当のテストビルドを起動し、実IPC・実本文iframeを操作できる。
2. テスト用WebDriver pluginは専用feature/build profileだけで有効にする。
3. 本番buildの依存・設定・待受socketを検査し、テストサーバが含まれない。
4. macOSで採用方式が動かない場合は理由と代替GUI harnessをADR化し、手動試験を必須の暫定gateとして扱う。テスト自体をskipで合格にしない。

ブラウザ上のVueテストだけではWKWebView / WebView2 / WebKitGTKのsandbox、CSP、ダイアログ、実IPCを検証したことにならない。

## 4. CIの安全性

- workflow permissionsは既定contents: read。release jobだけ必要な書き込みを付与する。
- PRは署名鍵・本物のメール資格情報なし。fork PRや未信頼コードへsecretsを渡さない。pull_request_targetでPRコードを実行しない。
- GitHub Actionsをレビュー済みfull commit SHAへ固定し、自動更新PRで追従する。コンテナはdigest固定。
- toolchainとlockfileを固定。lockfileを勝手に更新してCIを通さない。
- cache keyへOS/arch/toolchain/lock hashを含める。秘密やメールキャッシュを保存しない。
- ログ、スクリーンショット、失敗artifactは合成データのみ。保持期間を制限し、tokenの自動マスクだけに頼らない。
- lint/testのtimeout、job concurrency、cancel-in-progressを設定。releaseは中断を避ける専用group。
- 依存更新、RustSec、JS監査、ライセンス、secret scan、対応言語の静的解析を実施する。警告を無条件ignoreしない。

## 5. 成果物と署名

| 対象 | 成果物候補 | release gate |
|---|---|---|
| macOS arm64 / x64 | .app / .dmg、必要ならuniversal | Developer ID署名、hardened runtime、公証、staple、Gatekeeper起動 |
| Windows x64 | NSIS installer、必要時MSI | Authenticode署名・timestamp、クリーンVMインストール、更新・削除 |
| Ubuntu x64 | .deb + AppImage | package依存検証、hash/署名情報、実機起動、更新導線 |

OS署名とTauri updaterの署名は別の鍵・目的として管理する。updaterはHTTPSと署名検証を必須とし、改変・別製品・古い配信情報を拒否するアプリ側方針も試験する。秘密鍵をアプリへ同梱しない。キーrotationと紛失時の手動更新手順を用意する。

release secretsはprotected environmentまたは外部署名サービスへ置き、公開鍵・client IDと分ける。既に信頼されたCI成果物のみ署名する。検証用ビルドをそのまま署名して出荷しない。Tauri actionの設定は固定版の公式仕様を調べて生成する。[公式GitHub配布](https://v2.tauri.app/distribute/pipelines/github/)

配布前にclean install、旧安定版からのupgrade、DB migration失敗、ネット切断中更新、ロールバック可能性を試験する。DBが新形式なら旧版起動を拒否し、backup復元手順を提供する。初回安定版は自動更新を無理に出さず、署名済み手動更新でもよいが、その場合は自動更新対応を未実装と明記する。

## 6. リリース判定

AC-00〜23、性能目標、実プロバイダ認証、全対象OSとarchの実機チェックを満たす。署名資格情報やOAuth審査が準備できなければ、内部previewと一般公開を区別し、安定版完了にはしない。CI greenだけで公開可能と判断しない。
