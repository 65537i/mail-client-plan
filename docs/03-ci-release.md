# OS別CIと配布計画

## 1. ワークフロー構成

| Workflow | 起動 | 必須処理 |
|---|---|---|
| verify | PR / main | format、lint、typecheck、unit、UI component、依存監査、secret scan、設定検査 |
| native | main pushはUbuntuのbasic、PRは4 runnerのfull。手動は対象OS・モードを選択（既定all / full）。`docs/status.md`のみの変更では起動しない | basic / webview / fullを区別。fullでは従来のnative build・production検査・起動・protocol・実WebView試験を維持 |
| protocol | PR / main、Ubuntu | pinned IMAP/SMTP fixtureサーバ、TLS、fault injection、オフライン収束 |
| desktop | PR / main、3OS | 実WebView E2E、HTML攻撃、IPC拒否、再起動。GUI環境が必要 |
| compatibility | nightly / release | OS最低版/現行版、macOS 2 arch、WebView差異、長時間同期、fuzz corpus |
| release | protected tag + environment | 承認済みcommitの再ビルド、署名、公証、SBOM、hash、更新署名、draft release |

初期runner候補: ubuntu-24.04 / windows-2022 / macOSは利用可能なarm64・x64ラベルをPhase 00で検証して固定する。runnerラベルや内蔵OSは変更されうるため、対応する実機の最低OS試験を別に持つ。latestを製品の最低動作OSの証明にしない。

Linux: Tauri公式prerequisitesに従うWebKitGTK 4.1等を固定された環境に導入し、GUI試験はXvfb + D-Bus + Secret Serviceのセッションを準備する。コンテナfixtureはUbuntuで動かし、他OSはネイティブのscripted protocol serverを使う。全OSでDocker利用可能と仮定しない。

Windows: MSVC toolchain、WebView2、必要SDK。WebDriverを外部利用する場合はEdge/driver互換版を確認する。Credential Managerは実ユーザー環境も確認する。macOS: Xcode toolchain、deployment target、arm64/x64、Keychain・署名権限を分離する。

### nativeの短い検証ループ

Actions → native → Run workflowで最新のmainを選び、以下を指定する。旧runのRe-run jobsは旧commitを使うため、修正確認には新規実行を使う。

- `target`: `all` / `ubuntu-24.04-x64` / `windows-2025-x64` / `macos-14-arm64` / `macos-15-intel`
- `mode`:
  - `basic`: Rust format / workspace test / clippy、frontend typecheck / build。native release build、起動、protocol、実WebViewは未実行。
  - `webview`: security-test用Tauri build（frontend typecheck / buildを含む）と実WebView / SecretStore試験。Linux / macOSはfile-access監査も実行。WindowsのOS-level file監査は未実装。production build、起動smoke、protocol、Rust workspace test / clippyは未実行。
  - `full`: 従来の全チェック。選択したOSだけのfullは全OSの証跡ではない。

全モードの前にLinuxの短いplan jobでCI選択ロジックとmacOS trace解析のNode回帰試験を行い、失敗したら重いmatrixを開始しない。選択scopeと部分検証の注意をActions summaryへ記録する。PRと節目の`all / full`で全OSのgateを確認し、basic / webviewの成功を総合検証成功と読み替えない。

Rustのregistry / git依存と`target`をキャッシュし、OS・arch・runner・固定Rust版・lockfile / manifests / Cargo設定hashを区別する。同一モードを優先し、同じ依存条件の別モードからも復元可能。キャッシュhitでもbuild / testは省略しない。キャッシュは依存・ビルド出力のみで、資格情報ストア、監査trace、メールデータは含めない。初回はcold buildとなり、短縮量はrunnerで実測する。

同じevent・ref・対象・モードの古いrunだけをcancelし、pushによって進行中の手動調査をcancelしない。

fullのIMAP候補試験は`imap-poc,mime-poc`を併用し、BODY.PEEKで取得した合成literalからMIME解析までの統合試験も実行する。MIME単独の上限・診断試験は別stepで維持する。これは合成peerの試験であり、実IMAPサーバやliteralの読込中資源制限を保証しない。

同じIMAP targetで代替`imap-codec`の宣言長通知・入力分割時の制約・本文と最終statusの分離も評価する。codecはimap-poc限定のoptional依存で、本番default buildへは含めない。候補制約の再現test成功を採用gate合格と数えない。

既存framingの評価には別名optional依存の`imap-codec 2.0.0-alpha.7`も使用する。同じtargetで同時到着・分割入力・literal / 応答全体の上限を試験するが、test限定probeであり製品のTLS / session受信層を置き換えない。

同targetには1 KiB固定readとframingを結ぶ合成TLS受信試験も含む。上限・decode・EOF・期限・取消時の接続破棄と後続応答の保持を検証するが、製品のFETCH発行やUID / 最終tag照合との統合は別gateとする。

テスト限定の固定UID FETCH統合も同targetで実行し、上限付きTLS受信でUID / 完全BODY / 最終tagged OKと異常時の接続破棄を確認する。認証・mailbox選択・account scopeを実装した製品セッションの検証ではない。

同じbounded FETCHをSTARTTLS OK後のraw TCP→検証済みrustls streamへ引き継ぐ合成試験も実行する。STARTTLS拒否・未信頼証明書・hostname mismatchでFETCH / 認証へ進まず、plaintext fallbackをしないことを確認する。実サーバ・production connection managerの代替証跡にはしない。

さらにSTARTTLS昇格後のliteral上限超過、途中EOF、literal / 最終応答のdeadline・cancel時にprefix回収とTLS接続破棄を検証する。これは合成TLS peer上の試験で、実サーバやtask abort時の回収を保証しない。

IMAP候補targetには別途、STARTTLS昇格後にXOAUTH2 → EXAMINE INBOX → UIDVALIDITY / UIDNEXT取得 → 固定UIDのBODY.PEEK FETCHを同一のasync-imap sessionで行う合成試験を含める。FETCHはrun_command / read_responseで同一UID・完全BODY・一致tagged OKを明示確認する。これは小さい合成literalによるsession連携であり、bounded FETCH receiver、候補内部のliteral読込上限、account scope、UIDVALIDITY変更時の同期動作、実サーバへの接続は検証しない。

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
- `pnpm/action-setup` / `actions/cache`はNode.js 24 runtimeのv6.1.0をSHA固定で使用する。`setup-node`の`node-version`はrun step用であり、Action本体のruntimeは各Actionの`runs.using`で決まる。Node 20の警告を環境変数で抑制せずActionを更新する。self-hostedへ移す場合はNode 24対応runner（最低2.327.1）を準備する。
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
