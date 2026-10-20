# 開発状況

更新日: 2026-10-20

## 現在の範囲

- Phase 00、縦切り機能00B「危険な境界のPoC」のHTML/IPC部分をLinux arm64で実行確認
- 00BのSecretStore lock・3OS検証と00Cのprotocol / WebDriver比較は未完了。AC-18のFTS5小規模PoCに加え、IMAPのsynthetic peer検証、SMTP候補のfinal response/RCPT拒否をloopback sinkで確認。

## 実装

- Tauri 2 + Vue 3 + strict TypeScriptの最小アプリ、Rust workspace、lockfileを追加。
- Dev Containerを作成し、Docker Desktop上でlinux/arm64イメージをbuild。
- 4 runner候補のネイティブbuild / 起動smoke test workflowを追加。GitHub Actions run 3ではUbuntuとmacOS両arch成功、Windowsはtrusted UI IPC試験がtimeout。WDIO `executeAsync`内でTauri invokeを直接確認する方式へ整理し、Linux実WebViewで再検証済み。Windows runnerで再実行予定。
- 独自IPC commandと不要なopener pluginを初期アプリから除去。基礎CSPを設定。
- ADR-001へOS候補、runner候補、ツールチェーン、実機候補と未検証点を記載。
- `smoke-test` featureはCI用buildのみで自動終了し、通常buildへは含めない。
- 00B HTML/IPC隔離PoCを追加。暫定判断と未検証条件を[ADR-003](./adr/ADR-003-html-isolation-poc.md)に記録。
- 00B PoCとして合成攻撃HTMLを`sandbox=""`の`srcdoc` iframe内にのみ表示し、本文用CSPを設定。
- 独自IPC command `security_probe`をTauri AppManifestで明示し、単独permissionをmain capabilityだけへ付与。
- フロントは攻撃HTMLをトップDOMへ挿入せず、本文iframeにTauri APIを公開しない。
- WebdriverIO 9.31.9 + Tauri service 1.5.0のembedded WebDriver試験を追加し、Linux WebKitGTKでAC-05攻撃fixtureを実行。
- WebDriver plugin / IPC probe command / `withGlobalTauri` / WDIO capabilityを`security-test` featureと専用Tauri configに限定。production buildに含まれないことをスクリプトで検査。
- 4 native runner matrixへ実WebView試験を追加（GitHub Actions未実行）。
- SecretStoreはLinux Secret Service / macOS Keychain / Windows Credential Managerを明示する`keyring` backendを`security-test` featureだけに追加。平文file fallbackは実装しない。
- AC-06向けloopback TLS testでuntrusted certificate、hostname mismatch、STARTTLS refusalの各ケース後に合成認証payloadが0 bytesであることを確認。[ADR-004](./adr/ADR-004-secret-store-and-tls-poc.md)に暫定判断と限界を記録。
- security-test専用IPCでLinux Secret Service不在時の明示エラーに加え、一時展開したGNOME Keyring daemon下で合成secretの保存・読み出し・削除・削除後未登録を実WebViewで確認。commandにfile fallbackはないがfilesystem監視による直接証跡は未取得。
- native workflowにLinux用GNOME Keyringの起動とDBus service待機を追加し、3 OSのsecurity WebView試験でSecretStore成功系を必須化。workflowは未実行。
- AC-18の限定PoCを追加。SQLite bundled FTS5 trigramで日本語部分一致、NFKC/空白正規化、account scope、1〜2文字query拒否、FTS MATCH literal quotingをfixtureで確認。[ADR-006](./adr/ADR-006-japanese-trigram-search-poc.md)に結果と未達条件を記録。
- 00C IMAP候補としてasync-imap 0.12.0のTokio test-only integrationを追加。synthetic XOAUTH2 challenge、UIDVALIDITY、UID FETCH、IDLE stop後のDONE/selected-session再利用、IDLE非対応時のNOOP polling、rustlsのimplicit TLSおよびSTARTTLS upgrade、証明書不可信・hostname mismatch・STARTTLS拒否時の認証送信停止を確認し、未確定項目を[ADR-002](./adr/ADR-002-imap-candidate-poc.md)へ記録。
- 00C SMTP候補としてlettre 0.11.23の`tokio1` / `smtp-transport` featureのみを有効化する任意PoCを追加。loopback synthetic sinkでDATA final 250受理、final 550拒否status、RCPT拒否時のDATA未送出を確認し、TLS/unknown-state等の未達条件を[ADR-002](./adr/ADR-002-imap-candidate-poc.md)へ追記。

## 最新の確認

| コマンド / 確認 | 結果 |
|---|---|
| `pnpm run build` | 成功 |
| `cargo fmt --all --check` | 成功 |
| `cargo test --workspace --locked` | 成功。Rust test 0件 |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | 成功 |
| `cargo test -p mail-client --features security-test --test tls_auth_boundary --locked` | 成功。3 tests: untrusted certificate / hostname mismatch / STARTTLS refusalの全ケースで認証相当payload 0 bytes |
| `cargo test -p mail-client --features search-poc --test japanese_trigram_search --locked` | 成功。3 tests: 日本語substring / NFKC・account scope / short query reject・FTS literal quoting |
| `cargo test -p mail-client --features imap-poc --test imap_candidate --locked` | 成功。8 tests: XOAUTH2/UID semantics、IDLE cancellation後のDONEとsession再利用、IDLE非対応時のNOOP polling、implicit TLS/STARTTLS、証明書不可信・hostname mismatch・STARTTLS拒否時のIMAP認証送信0 |
| `cargo clippy -p mail-client --test imap_candidate --features imap-poc --locked -- -D warnings` | 成功 |
| `cargo test -p mail-client --features smtp-poc --test smtp_candidate --locked` | 成功。3 tests: final 250 response、DATA後final 550 status取得、RCPT拒否時DATAなし |
| `cargo clippy -p mail-client --test smtp_candidate --features smtp-poc --locked -- -D warnings` | 成功 |
| default dependency graph (`cargo tree -p mail-client --edges normal --no-default-features`) | `async-imap` / `imap-proto` / `rcgen` / `rustls` / `tokio-rustls`なし。IMAP/TLS候補crateはPoC featureのみ |
| `cargo clippy -p mail-client --all-targets --features search-poc --locked -- -D warnings` | 成功 |
| default dependency graph (`cargo tree -p mail-client --edges normal --no-default-features`) | `rusqlite` / `unicode-normalization`なし。PoC依存はproduction defaultから除外 |
| `cargo clippy --workspace --all-targets --features security-test --locked -- -D warnings` | 成功 |
| `cargo check -p mail-client --features security-test --bin mail-client --locked` | 成功 |
| `pnpm exec tauri build --no-bundle --ci` | 成功。Linux arm64 |
| `pnpm exec tauri build --no-bundle --ci --features security-test --config src-tauri/tauri.security-test.conf.json` | 成功。Linux arm64 security-test app |
| `xvfb-run -a dbus-run-session -- pnpm exec wdio run wdio.security.conf.mjs`（keyring daemonなし） | 成功。WebKitGTK 2.50.6、2 specs pass。AC-05はscript marker 0 / 外部HTTP request 0 / top URL不変 / iframe親DOMアクセス不可 / trusted UI IPC成功。AC-06はSecret Service不在時の明示エラーを確認 |
| `xvfb-run -a dbus-run-session -- ... gnome-keyring-daemon ... wdio.security.conf.mjs` | 成功。Linux WebKitGTKで2 specs pass。AC-06 Secret Service合成secretのsave/read/delete/delete後未登録を確認 |
| GitHub Actions `native` run 1 (`79eae23`) | Ubuntu 24.04 x64とmacOS 14 arm64成功。Windows 2025はbuild・Rust tests・SMTP/IMAP PoCが成功した後、実WebView WDIOで実行ファイル`.exe` path不足により失敗。macOS 15 Intelはcancelled。 |
| GitHub Actions `native` run 2 (`bf1bc71`) | Ubuntu 24.04 x64、macOS 14 arm64、macOS 15 Intelが成功。Windows 2025の`.exe`解決は修正されたが、AC-05 trusted UI button操作のWDIO workerがtimeoutで失敗。 |
| GitHub Actions `native` run 3 (`984cc4a`) | Ubuntu 24.04 x64、macOS 14 arm64、macOS 15 Intelが成功。Windows 2025はAC-05 trusted UI IPCテストのWDIO hook timeoutで失敗。 |
| `xvfb-run -a dbus-run-session -- pnpm run test:security:desktop` | 成功。ローカルLinux実WebViewで2 specs pass（iframe isolationとtrusted UI IPCを含む）。 |
| WDIO trusted UI command test | ボタンのイベント駆動から、WDIO `executeAsync`内でTauri invokeを直接行い結果をassertする方式へ変更。Windows CI再実行待ち |
| native workflow SecretStore success gate / Japanese FTS5 / IMAP / SMTP PoC | run 3で全4 runnerの該当PoC tests成功。LinuxはGNOME Keyring DBus service待機後にWDIO実行 |
| `actionlint -color .github/workflows/native.yml` (1.7.12) | 過去のworkflow更新時に成功。今回のworkflow変更なし |
| `pnpm run check:production-security` | 成功。normal production buildにWDIO plugin / permissions / global Tauri APIなし |
| `pnpm install --frozen-lockfile` | 成功。pnpm 12.14.0 |
| Tauri生成ACL manifest | `security-test` buildで`security_probe`のallow/deny permissionを生成し、test capabilityからのみ解決 |
| Linux実WebViewのscript/外部通信/top navigation / opaque origin | 上記WDIO試験で確認。file URLのOS-level resource readは直接未確認 |
| 3OS実WebView攻撃試験 | 未確認。4 runnerとOS実機が必要 |
| SecretStore backend拒否 | Linux sessionでdaemon不在時に明示エラーを確認。commandにfile fallbackなし。filesystem監視は未実施 |
| SecretStore save/read/delete成功 | 一時GNOME Keyring daemon下でLinux実WebView成功を確認 |
| SecretStore lock / access denied | 未確認。OS GUI sessionと各OS実機が必要 |
| async-imap TLS否定経路 | 不可信証明書・hostname mismatch・STARTTLS拒否すべてについて、IMAP synthetic fixtureのTLS application dataが0 bytesであることを確認 |
| SMTP候補の異常系 | loopback sinkでSMTP final 550 statusを取得、RCPT拒否でDATA送信なしを確認。lost final responseのunknown分類とSMTP TLS設定は未確認 |

## ローカル検証証跡

| コマンド / 確認 | 結果 |
|---|---|
| `pnpm run build` | 成功。Vue typecheck + Vite production build |
| `cargo fmt --all --check` | 成功 |
| `cargo test --workspace --locked` | 成功。Rust test 0件 |
| `cargo clippy --workspace --all-targets --locked -- -D warnings` | 成功 |
| `pnpm exec tauri build --no-bundle --ci` | 成功。Linux arm64 native build。command ACL生成を含む |
| `cargo build --release --locked --features smoke-test --bin mail-client` | 成功 |
| `xvfb-run -a dbus-run-session -- env WEBKIT_DISABLE_COMPOSITING_MODE=1 ./target/release/mail-client` | 成功。GUI smoke launch後に終了、exit code 0 |
| `docker build -f .devcontainer/Dockerfile -t mail-client-dev:local .` | 成功。linux/arm64。Node 24.22.0、Rust 1.99.1、pnpm 12.14.0を確認 |
| `pnpm install --frozen-lockfile` | 成功。pnpm 12.14.0 |
| 4 runnerのbuild / GUI起動・終了 | GitHub runner未実行のため未確認 |

## Phase 00のAC状況

| AC | 状態 | 証拠 / 次の確認 |
|---|---|---|
| AC-00 | 部分確認 | Dev Container linux/arm64でbuild・起動・終了。4 runnerと対象最低OSの実機証跡が必要 |
| AC-05 | 部分確認（Linux arm64のみ） | WebKitGTK real WebViewでscript marker 0、外部HTTP request 0、top document不変、iframe親DOM access拒否。Linuxでもfile URLのOS-level read未計測。macOS / Windows試験が必要 |
| AC-06 | 部分確認（Linux PoC） | loopback 3 casesで認証相当payload 0 bytes。Secret Service不在時の明示失敗およびdaemon稼働時の合成値save/read/deleteを確認。lock/拒否の実証、3OS provider、実protocol統合は未確認 |
| AC-18 | 部分確認（fixture PoC） | Japanese FTS5 trigram testで日本語3+文字部分一致、NFKC/空白、account scope、1〜2文字拒否を確認。100k/性能基準、正規化versioning、structured search/UIは未実装 |
| AC-22 | 未着手 | 00Cで本番buildにテストplugin / debug portがないことを確認 |

## Gateと未解決事項

- AC-00は未完了。4 runnerのCI結果と対象最低OSの実機証跡が必要。ローカルsmoke testはLinux arm64コンテナのみ。
- macOS/Windowsの実機、Windows WebView2、3OS AC-05 / SecretStore、署名・配布は未確認。
- iframeのsandbox / CSP / IPC隔離はLinux WebKitGTKで限定確認済み。file URLの画像resource openは直接計測しておらず、AC-05全体は未達。
- Google/Microsoft資格情報、実メール、送信は使用していない。
- このworkspaceにはGit repository / remoteがなく、GitHub Actionsを起動していない。

## 次の最小タスク

- CIを実行し、Ubuntu / Windows / macOS各WebViewで同じAC-05攻撃試験の結果を記録する。file resource openの直接観測手段を用意して追加確認する。
- Linux CIでkeyring success gateを確認し、macOS / Windowsでも実WebView SecretStore successを確認する。OS別lock / access-deniedを試験し、実IMAP/SMTP実装後はAC-06契約をprotocol adapterへ接続する。
- ADR-006のPoCを基にPhase 07で正規化version、FTS同期、短いqueryのscope付き制限検索、100k性能計測を実装・検証する。
- ADR-002のasync-imap候補はIDLE cancellation / TLS transportのgateを通すまで採用確定しない。
