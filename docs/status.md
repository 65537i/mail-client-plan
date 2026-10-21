# 開発状況

更新日: 2026-10-21

## 現在の範囲

- Phase 00、縦切り機能00B「危険な境界のPoC」のHTML/IPC実WebView試験をLinux arm64と4 native CI runnerで確認
- SecretStore lock/access-denied、Windows/macOSのfile URL監査の完全性、最低サポートOSの実機確認は未完了。macOS run 22ではfs_usageでOS daemonのmetadata参照を検出したが、全WebKit process coverageは未証明。Windows Process Monitorは未実装。00CではIMAPのsynthetic peer検証、SMTP候補のfinal response/RCPT拒否をloopback sinkで確認したが、候補採用判断は未完了。
- 待ち時間を抑えるため、nativeはmain pushでUbuntu / basic、PRで全4 runner / full。手動は対象OSとbasic / webview / fullを選べる（既定all / full）。Rust cacheと軽量Node試験の前倒しを追加。status-only起動除外とPRの全OS gateは維持。部分検証の成功を全体成功には数えない。操作は[CI計画](./03-ci-release.md)を参照。

## 実装

- Tauri 2 + Vue 3 + strict TypeScriptの最小アプリ、Rust workspace、lockfileを追加。
- Dev Containerを作成し、Docker Desktop上でlinux/arm64イメージをbuild。
- 4 runner候補のネイティブbuild / 起動smoke test workflowを追加。GitHub Actions run 9でUbuntu 24.04 x64、Windows 2025 x64、macOS 14 arm64、macOS 15 Intelすべて成功。Windows WebViewのAC-05はtrusted UI IPC、iframe攻撃fixture、post-load検査を通過し、HTTP fixture serverを0 requestで終了。
- 独自IPC commandと不要なopener pluginを初期アプリから除去。基礎CSPを設定。
- ADR-001へOS候補、runner候補、ツールチェーン、実機候補と未検証点を記載。
- `smoke-test` featureはCI用buildのみで自動終了し、通常buildへは含めない。
- 00B HTML/IPC隔離PoCを追加。暫定判断と未検証条件を[ADR-003](./adr/ADR-003-html-isolation-poc.md)に記録。
- 00B PoCとして合成攻撃HTMLを`sandbox=""`の`srcdoc` iframe内にのみ表示し、本文用CSPを設定。
- security-test専用IPC command `secret_store_probe`をTauri AppManifestで明示し、単独permissionをmain capabilityだけへ付与。
- フロントは攻撃HTMLをトップDOMへ挿入せず、本文iframeにTauri APIを公開しない。
- WebdriverIO 9.31.9 + Tauri service 1.5.0のembedded WebDriver試験を追加し、Linux WebKitGTKでAC-05攻撃fixtureを実行。
- WebDriver plugin / SecretStore probe command / `withGlobalTauri` / WDIO capabilityを`security-test` featureと専用Tauri configに限定。production buildに含まれないことをスクリプトで検査。
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
| GitHub Actions `native` run 4 (`82d7649`) | Ubuntu 24.04 x64、macOS 14 arm64、macOS 15 Intelが成功。Windows 2025もbuild、TLS / FTS5 / IMAP / SMTP、SecretStore試験まで成功したが、AC-05の`security_probe` IPCテストが30秒timeoutで失敗。ログではiframe specのtrusted UI IPC test hook timeoutを確認。 |
| GitHub Actions `native` run 5 (`9560492`) | Ubuntu 24.04 x64とmacOS 14 arm64成功。Windows 2025はRust / protocol / SecretStore試験成功後、run 4と同じAC-05 trusted UI IPC hook timeout。SecretStore spec自体は成功。macOS 15 IntelはWindows失敗後にcancelled。 |
| GitHub Actions `native` run 6 (`58e8f04`) | Ubuntu 24.04 x64とmacOS 14 arm64成功。Windows 2025はRust / protocol / SecretStore試験成功、SecretStore specも成功したが、iframe spec内のtrusted UI IPC testでrun 4/5同様のtimeout。macOS 15 Intelは未完了時点。 |
| GitHub Actions `native` run 7 (`4b8ebd5`) | Ubuntu 24.04 x64、macOS 14 arm64、macOS 15 Intel成功。Windows 2025はtrusted UI IPC checkを通過したが、AC-05 hostile fixture testがtimeout。エラーは`blocks script, external requests, and file/top navigation attempts`に紐づく。 |
| GitHub Actions `native` run 8 (`8478910`) | Ubuntu 24.04 x64、macOS 14 arm64、macOS 15 Intel成功。Windows 2025ではAC-05のtrusted UI IPC、fixture injection、post-load WebDriver inspectionが返った後にafterAll timeout。最後のログは検査scriptの完了で、HTTP probe serverのclose待ちが候補。 |
| GitHub Actions `native` run 9 (`d37a2bf`) | Ubuntu 24.04 x64、Windows 2025 x64、macOS 14 arm64、macOS 15 Intelすべて成功。Windowsの実WebView security stepは2 specs pass、hostile fixture後のprobe server close成功、外部request 0。TLS / FTS5 / IMAP / SMTP testsもmatrix内で成功。 |
| GitHub Actions `native` run 10 (`26708f5`) | status記録のみの更新。Ubuntu 24.04 x64、Windows 2025 x64、macOS 14 arm64、macOS 15 Intelすべて成功。 |
| GitHub Actions `native` run 11 (`4127091`) | Ubuntu 24.04 x64で`strace`によるAC-05 Linux file-access監査が成功。実Tauri appを含む88 processを追跡し、合成canaryへのfile syscall 0件。WebViewとSecretStoreの2 specsも成功。Windows 2025 x64とmacOS 14 arm64も成功。macOS 15 Intelは完了前に後続pushでcancel。 |
| GitHub Actions `native` run 12 (`179ac74`) | status更新commitで起動した従来設定の4 runner run。後続pushでcancel。 |
| GitHub Actions `native` run 13 (`51de6e1`) / run 14 (`903a5b8`) | matrix絞り込み設定がjob生成前に失敗。matrixの構造を修正し、actionlintとrun 15で検証。 |
| GitHub Actions `native` run 15 (`969eebe`) | mainへのpushでUbuntu 24.04 x64の1 jobのみを起動し、全チェック成功。PR / workflow_dispatchの4 runner matrixは式上有効だが、このrunでは未実行。 |
| GitHub Actions `native` run 16 (`88a3ff8`) | mainへのpushでUbuntu 24.04 x64の1 jobのみを起動し、全チェック成功。 |
| GitHub Actions `native` run 17 (`7d61653`) | Ubuntu 24.04 x64で実行。後続pushによりcancelされ、全step完了前に終了。 |
| GitHub Actions `native` run 18 (`643efe3`) | Ubuntu 24.04 x64の全チェック成功。macOS / Windows計測方法を調査・記録した更新を検証。 |
| GitHub Actions `native` run 19 (`5794400`) | Ubuntu 24.04 x64の全チェック成功。Linuxの既存file-access auditとWebViewを確認。macOS専用harnessはpush時matrixの対象外のため未実行。 |
| GitHub Actions `native` run 20 (`fc919fc`, 手動) | Ubuntu、Windows、macOS 14 arm64成功。macOS 15 IntelはWebView / SecretStoreの2 specs成功後、system-wide fs_usage traceのcanary名検出で失敗。アクセス元をログへ出さずtraceを削除していたため、WebView起因か別process起因かは確定不能。テスト完了から監査終了まで約76秒の余分な観測時間も確認。 |
| run 20への対策（AC-05） | sudo側へのSIGINTだけでなく、pid fileに記録したfs_usage本体をsudoで明示停止するよう修正。監査がWebView試験中に終了した場合も失敗にする。canary検出は引き続き全processで失敗させ、最大10件のoperation / process-thread名と総件数だけを診断表示（生path / traceは非公開・削除）。Node回帰5 tests、構文検査、actionlint、diff検査成功。macOSでの再実行は未確認。 |
| GitHub Actions [native run 22](https://github.com/65537i/mail-client-plan/actions/runs/39606500689) (`ef6259d`, 手動) | 調査時点でrun全体は進行中。macOS 14 arm64はWebView / SecretStore 2 specs成功、HTTP 0件後に監査失敗。内訳は`lstat64 / fseventsd.2298`の1件。OS daemonのmetadata参照をアプリの攻撃と区別していなかった。終了処理はWDIO終了から約1秒で判定でき、run 20の余分な約76秒は解消。Intel等の最終結果は未確認。 |
| run 22対策とCI短縮（AC-00 / 05 / 22） | 利用者確認済みでfseventsdのlstat64だけを別集計・明示報告。それ以外のcanaryイベントと未知formatは失敗を維持。全WebView coverageは未証明、AC-05全体は未達。CIの15通りの手動選択、push / PR選択、出力CLI、監査分類を含むNode 12 tests成功。node構文、actionlint 1.7.12、diff検査成功。変更後のmacOS実機・Actions実行、キャッシュ効果の実測は未実施。 |
| `xvfb-run -a dbus-run-session -- pnpm run test:security:desktop` | 成功。ローカルLinux実WebViewで2 specs pass（iframe isolationとtrusted UI IPCを含む）。 |
| Linux file URL OS-level audit | native run 11で成功。`strace -ff -e trace=%file`がTauri/WebViewを含む88 processを追跡し、一時ディレクトリの合成canaryへのfile syscall 0件。ローカルはstrace未導入のためCIで実行 |
| macOS / Windows file URL OS-level audit候補 | macOS fs_usageのroot観測とdaemonイベント解析はrun 22 arm64で確認。全WebKit coverage / positive controlは未確認。Windows Microsoft Sysinternals Process Monitorはcapture/export・権限・process追跡を含め未実装。AC-05全体の合格には数えない |
| macOS file-access audit harness | `scripts/test-macos-file-access.mjs`でsudoの一時traceを検証し、記録したfs_usage PIDを明示停止。Tauri appの観測を必須とし、fseventsd lstat64以外のcanaryイベントを拒否。生traceは削除。限定分類後のmacOS runner実行は未確認 |
| `node --check` / `cargo fmt --all --check` / `git diff --check` | 成功。file audit harnessとWDIO設定を含む |
| `pnpm run check:production-security` | 成功。production buildにtest-only IPC / WebDriver pluginなし |
| WDIO trusted UI / hostile fixture tests | `executeAsync`内の明示許可IPC確認をfixture注入前に行い、HTTP probe server close時にactive connectionsを終了。run 9で4 runnerすべて成功 |
| native workflow SecretStore success gate / Japanese FTS5 / IMAP / SMTP PoC | run 9で4 runnerすべての該当tests成功。LinuxはGNOME Keyring DBus service待機後にWDIO実行 |
| `actionlint -color .github/workflows/native.yml` (1.7.12) | 成功。main pushでUbuntuのみ、PR / workflow_dispatchで4 runnerのmatrixを生成し、status-only changeを除外する条件をlint |
| `pnpm run check:production-security` | 成功。normal production buildにWDIO plugin / permissions / global Tauri APIなし |
| `pnpm install --frozen-lockfile` | 成功。pnpm 12.14.0 |
| Tauri生成ACL manifest | `security-test` buildで`secret_store_probe`のallow/deny permissionを生成し、test capabilityからのみ解決 |
| 実WebViewのscript/外部通信/top navigation / opaque origin | run 9でLinux / Windows / macOS両archのrunnerで確認。file URLのOS-level resource readは直接未確認 |
| 3OS実WebView攻撃試験 | 4 runnerでCI確認済み。対象最低OSの実機試験とfile URLのOS-level read直接観測は未完了 |
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
| 4 runnerのbuild / GUI起動・終了 | GitHub Actions native run 9でUbuntu 24.04 x64、Windows 2025 x64、macOS 14 arm64、macOS 15 Intel成功。最低サポートOSの実機証跡は別途必要 |

## Phase 00のAC状況

| AC | 状態 | 証拠 / 次の確認 |
|---|---|---|
| AC-00 | 部分確認 | Linux arm64 Dev Containerと4 native CI runnerでbuild・起動smoke test成功。対象最低OSの実機証跡が必要 |
| AC-05 | 部分確認（4 CI runner） | run 9でLinux / Windows / macOS両archの実WebViewにてscript marker 0、外部HTTP request 0、top document不変、sandbox iframe親DOM access拒否、trusted IPCを確認。run 11のLinux `strace`監査で88 processを追跡し、synthetic file canaryへのfile syscall 0件を確認。Windows/macOSのOS-level直接観測と最低OS実機試験は未実施 |
| AC-06 | 部分確認（4 CI runner） | TLS否定3 casesで認証payload 0 bytes、SecretStoreの合成値save/read/delete成功と未導入時の明示エラーを確認。OS別lock/access-denied、filesystem監視によるfallback不在の直接証跡、実protocol統合は未確認 |
| AC-18 | 部分確認（fixture PoC） | Japanese FTS5 trigram testで日本語3+文字部分一致、NFKC/空白、account scope、1〜2文字拒否を確認。100k/性能基準、正規化versioning、structured search/UIは未実装 |
| AC-22 | 未着手 | 00Cで本番buildにテストplugin / debug portがないことを確認 |

## Gateと未解決事項

- AC-00は未完了。4 runnerのCI結果は成功したが、対象最低OSの実機証跡が必要。
- 3OS候補runnerのAC-05攻撃試験とSecretStore成功経路はCIで確認済み。Linux `strace`のfile URL観測もrun 11で成功した。OS別lock/access-denied、Windows/macOSでの同等OS-level観測、署名・配布は未確認。
- iframeのsandbox / CSP / IPC隔離はrun 9で4 runner確認済み。Linuxで合成canaryへのfile syscall 0件を確認したが、他OSと最低OS実機は未確認のためAC-05全体は未達。
- Google/Microsoft資格情報、実メール、送信は使用していない。
- GitHub Actions native run 9は全4 runnerで成功。Private repositoryは`65537i/mail-client-plan`。

## 次の最小タスク

- 新しいmainでnativeを`macos-14-arm64 / webview`に絞って検証し、次に必要に応じて`macos-15-intel / webview`で原因を確認する。旧runのRe-runではなくRun workflowを使う。節目に`all / full`を実行する。macOSの全WebKit process coverage / positive control、Windows Process Monitorの合成canary PoC、対象最低OSの実機試験も必要。
- OS別SecretStore lock / access-deniedを試験し、実IMAP/SMTP実装後はAC-06契約をprotocol adapterへ接続する。
- ADR-006のPoCを基にPhase 07で正規化version、FTS同期、短いqueryのscope付き制限検索、100k性能計測を実装・検証する。
- ADR-002のasync-imap候補はIDLE cancellation / TLS transportのgateを通すまで採用確定しない。
