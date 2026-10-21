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
- 00C SMTPのlost / truncated final response fixtureを追加。DATA終端まで受信後に切断する2経路で、受理成功扱いにせず、本文受信1件・DATA 1回・250msの観測窓内に自動再接続なしを確認。fixtureのcommand / DATA途中EOFも明示エラーにして無限ループを防止。永続Outboxのunknown状態・再起動復旧は未実装。
- 00C SMTP TLS認証境界の8ケースを追加。lettreのrustls / 必須STARTTLSをPoC featureだけに追加し、合成rootの証明書・hostname検証を維持。暗黙TLS / STARTTLS後のみ合成認証を許可し、否定経路の認証0回を検証。TLS上の本文送信・本番adapterは未実装。
- SMTP TLS fixtureを本文送信へ拡張。暗黙TLS / 必須STARTTLSそれぞれで最終250・550・応答消失を試験し、認証 / envelope / DATAが暗号化後各1回、合成本文のwire bytes一致、lost reply時の成功誤判定なし・250ms内の再接続なしを確認。本番送信UI / adapter / Outboxは未実装。

## 最新の確認

MIME重複CID診断（00C / AC-04 / AC-05の前提PoC）: `MimeDiagnostics`へ`duplicate_content_id`を追加。同じMessage内の空でないContent-IDを完全一致で比較し、重複をboolで明示する。添付messageごとに集合を分離し、外側・別の添付messageとのCID一致は重複扱いにしない。添付message内部の重複は全体診断へ集約する。原文・添付は拒否 / 削除せず、既存parse契約を維持。新規3 testsで重複 / 一意 / 大小文字 / CIDなし / 添付messageの境界 / nested重複 / 診断への生CID非公開を確認。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit5 + integration33 = 38 tests成功、対象clippy `-D warnings` / format / diff成功。CID URL復号・multipart/relatedごとの名前解決・画像形式検証・表示許可判定ではない。UI / IPC / 外部取得には未接続。新依存・workflow変更なし。解析途中の資源制限、Windows/macOSは未検証、全OS手動Actionsは起動せず、Phase 00未完了。

MIME文字コード診断API（00C / AC-04耐性PoC）: `parse_with_diagnostics`を追加し、Messageと本文診断の2 flagsを返す。未知の宣言charsetと、decoded text / HTML中のU+FFFDの存在を分離し、既存の反復tree走査で添付message内部・text添付も確認する。固定版parserと同じcharset decoder mapを使い、default経路のUTF-8は別途認識。既存`parse`の受理 / エラー / 本文は維持し、診断に本文・charset生値・pathを含めない。U+FFFDが元から含まれる場合もflagが立つため「変換で文字欠落が起きた」とは断定しない。charset未指定・binaryは未知charset扱いにせず、header charsetは対象外。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit5 + integration30 = 35 tests成功、対象clippy `-D warnings` / format / diff成功。新規4 testsで不正UTF-8 / 元からのU+FFFD / 未知charset / 日本語 / HTML / nested text / binary除外 / 原文保持 / 既存APIとの一致 / 診断非公開を検証。新依存・workflow変更なし。UI / IPCは未接続、全変換損失検出・解析途中の資源制限・Windows/macOSは未検証。全OS手動Actionsは起動せず、Phase 00未完了。

MIME base64添付上限検証（00C / AC-04耐性PoC）: 通常添付（multipart/mixed）とinline画像指定（multipart/related）を各25MiB -1 / 境界 / +1 byteの6ケースで生成。76文字改行・末尾paddingを含むbase64を実復号し、全bytes一致と原文保持を確認。候補parserは全ケースを解析し、adapterは両指定で境界以下を許可、+1 byteをAttachmentTooLargeで拒否した。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit5 + integration26 = 31 tests成功（integration約7.95秒）。対象clippy `-D warnings` / format / diff成功。製品コード・依存・workflow変更なし。image/pngはMIME分類試験用の宣言でpayloadは合成ASCII、画像形式検証・CID表示・sanitizerの証拠ではない。解析途中のCPU / memory制限、実IMAP、Windows/macOSは未検証。全OS手動Actionsは起動せず、Phase 00未完了。

MIME添付messageの解析打切り検証（00C / AC-04耐性PoC）: quoted-printableで包んだmessage/rfc822を1 / 2 / 3 / 4 / 5段で生成。mail-parser 0.11.9は3段まで展開し、4段目では復号bytesをBinaryとして保持してis_encoding_problemを設定することを確認。adapterは3段以下を許可、4 / 5段はIncompleteで拒否し、元EMLと未解析部分の全bytesを検査した。これは製品のcontainer上限30とは別の候補parserの制限。初回のfixture配置コンパイルエラーを修正し、未解析bytesの期待値も各層の元データとの完全一致へ修正。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit5 + integration25 = 30 tests成功。対象clippy `-D warnings` / format / diff成功。製品コード・依存・workflow変更なし。base64添付message、混在encoding、不完全MIME診断の網羅性、解析中の資源制限、Windows/macOSは未検証。全OS手動Actionsは起動せず、Phase 00未完了。

MIME実復号budget検証（00C / AC-04耐性PoC）: Windows-1252の0x80がUTF-8の3 byteへ展開される合成EMLを追加。原文50MiB未満から、復号後100MiB - 1 / 100MiB / 100MiB + 1 byteを実際に生成し、全decoded bytesと原文保持をassert。候補parserは3ケースとも解析し、adapterは境界以下を許可、+1 byteをDecodedTooLargeとして拒否することを確認。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit5 + integration24 = 29 tests成功（integration約6.50秒）。初回clippyの固定長chunks指摘をas_chunksへ修正後、新規test再実行と対象clippy `-D warnings` / format成功、diff検査成功。製品コード・依存・workflow変更なし。解析後の上限検査であり、解析途中のCPU / peak memory制限や計測の証拠ではない。Windows/macOS・実IMAP・全OS手動Actionsは未実行。

MIME非同期readの連続Interrupted対策（00C / AC-04耐性PoC）: Interruptedの再試行でも共通のyieldを通し、単一thread executorで取消taskを飢餓状態にしないよう修正。prefix受信後、最初のInterruptedで別taskへ取消を予約する回帰試験を追加。修正前は64回の有限readでI/Oエラーとなり取消assertが失敗、修正後は64回未満でCancelledと同一prefixの回収を確認。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit5 + integration23 = 28 tests成功。対象clippy `-D warnings` / format / diff成功。同期reader・依存・workflowは変更なし。Windows/macOS、実IMAP、解析中のCPU・メモリ制限は未検証。全OS手動Actionsは起動しておらず、AC-04全体やPhase 00の完了ではない。

MIME非同期read PoC: `read_source_async`に絶対deadlineと取消Futureを追加。取消・期限・readの順で判定し、途中中断でもprefixを回収しreaderの未読部分を保持する。50MiB + 1 byte上限とI/Oエラーの伏字診断を維持。Tokio既存固定版をmime-pocだけで有効化（新crate / lock更新なし）。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit5 + integration22 = 27 tests成功、対象clippy `-D warnings` / format / diff成功。初回の期限切れ＋ready read競合は毎loopの期限比較で修正して回帰試験成功。IMAP literal framing / session中断復旧、解析中のCPU・メモリ制限、future自体drop時のprefix回収、Windows/macOSは未確認。重い全OS手動runは起動せず、既存fullのMIME stepで検証可能。

MIME stream読み取り上限PoC: `read_source`を追加。原文50MiBちょうどのEOFを許可し、最大50MiB + 1 byteで超過を判定して未読streamを残す。I/Oエラー・上限超過時に部分原文と元エラーを回収でき、Display / Debug / source経由で本文・private path詳細を公開しない。Interruptedのみ再試行、その他のread失敗を成功にしない。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit5 + integration16 = 21 tests成功。対象clippy `-D warnings` / format / diff成功。依存・workflow変更なし、既存fullのMIME stepに含まれる。blocking PoCでありUI thread使用・実IMAP接続はなし。read中のdeadline / cancellation、部分原文の永続保存、解析中の資源制限、Windows/macOSは未検証。

MIME制限adapter PoC: `mime-poc`限定のRust moduleを追加し、raw 50MiB超過を解析前に拒否、attachment 25MiB / decoded合計100MiB / container深さ30超過を解析後に型付きエラーで拒否する。nested messageの元bytesとdecoded leavesを保守的に両方合算し、添付message内の深さも走査。原文はcallerのborrowed sliceとして保持し、エラーに原文を含めない。`Incomplete`は転送エンコード問題・空multipart・分類された本文も添付もない結果を対象とし、全不正MIMEの検出ではない。HTML安全化・charset診断は未実装。Linux arm64で`cargo test -p mail-client --features mime-poc --lib --test mime_candidate --locked`: unit 1 + integration 16 = 17 tests成功。対象clippy `-D warnings` / format / diff / actionlint成功。初回の追加test配置で検出漏れ警告が出たためscopeを修正し、全17件の実行と警告なしを再確認。fullのMIME stepに`--lib`を追加。解析中のCPU / メモリ制限、stream入力上限、Windows/macOS、UI / DB接続は未実施。

MIME耐性追加検証: `cargo test -p mail-client --features mime-poc --test mime_candidate --locked`でLinux arm64の11 tests成功（既存6 + 追加5、test本体約2.11秒）。対象clippy `-D warnings` / format / diff検査成功。不正UTF-8は置換文字となり、未知charsetのASCIIはfallbackするが、両者ともencoding問題flagはfalse。multipart深さ29 / 30 / 31 / 128、添付25MiBおよび原文50MiBの各-1 / 境界 / +1 byteを実測し、パーサが製品上限超過を拒否しないことを確認。全bytes・part tree・末端本文をassertしている。上限の適用実装、復号後合計100MiB、解析中の資源制限は未着手で、耐性保証・AC完了とは扱わない。Windows/macOS未実行。既存fullのMIME stepに自動的に含まれ、workflow・依存変更や追加の重い手動runはない。

MIME候補の初期PoC: `mail-parser =0.11.9`（optional `mime-poc`、`full_encoding`）を追加。Linux arm64で`cargo test -p mail-client --features mime-poc --test mime_candidate --locked`の6 tests成功、同targetのclippy `-D warnings`、format、diff、actionlint成功。日本語3 charset / RFC 2047、alternative、RFC 2231危険添付名とdecoded bytes、重複CID、不正base64、truncated multipartを検証。HTMLのscript・危険な名前・CID重複は除去されない。truncated multipartはparse成功でも本文なしとなる実測制約を記録した。default dependency treeにmail-parserなしを確認。native fullへ追加し、Windows/macOS・巨大 / 深いMIME・fuzz・製品のサイズ制限adapterは未確認。UI / IPC / 添付保存には未接続、AC-04は未完了。

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
| GitHub Actions [native run 23](https://github.com/65537i/mail-client-plan/actions/runs/39610151925) (`630b8af`, push) | Ubuntu / basic成功。run作成13:41:10から完了13:45:12 UTCまで4分02秒。基本チェックのみで、production build / 起動 / protocol / 実WebViewの証跡には数えない。 |
| GitHub Actions [native run 24](https://github.com/65537i/mail-client-plan/actions/runs/39611373351) (`630b8af`, 手動) | planとmacOS 14 arm64 / webviewの2 jobsのみで成功。run作成13:49:27から完了13:53:53 UTCまで4分26秒。security-test buildは3分20秒、実WebView監査stepは10秒。iframe / SecretStore 2 specs成功、HTTP 0件。fseventsd lstat64を1件別集計し、その他のcanaryイベント0件。停止・分類修正とOS / モード選択をrunner上で確認。full / 他OS / 最低OS実機 / 全WebKit coverageは未確認。 |
| run 24 Rustキャッシュ | macOS ARMのRustキャッシュ約458 MBを保存成功。次回以降の復元用データが作成された。warm cacheによる短縮効果は未計測。fullとwebviewは検証範囲が異なるため、run 20等との差をキャッシュ効果として扱わない。 |
| GitHub Actions [native run 25](https://github.com/65537i/mail-client-plan/actions/runs/39612476412) (`3c7ba3c`, 手動) | macOS 15 Intel / webview成功。iframe / SecretStore 2 specs成功、HTTP 0件、fseventsd lstat64別集計0件、その他canaryイベント0件。Rustキャッシュ約455 MBを保存。ARMとIntel双方で修正後の部分検証成功。全WebKit coverage / positive controlとfullは別途未達。 |
| Action runtimeのNode 20非推奨警告 | アプリ用Node 24.22.0とは別に、旧pnpm/action-setup v4とactions/cache v4がnode20を宣言していた。公式v6.1.0のaction.ymlでnode24を確認し、双方をfull SHA固定で更新。pnpm 12.14.0、Node 24.22.0、キャッシュkey、検証範囲は維持。actionlint 1.7.12とdiff検査成功。変更後のActionsで警告不在を確認する必要がある。 |
| SMTP lost response PoC（AC-13の前提検証） | `cargo test -p mail-client --features smtp-poc --test smtp_candidate --locked`: Linux arm64で5 tests成功（既存3 + lost / truncated response 2）。同対象のclippy `-D warnings`、format、diff検査成功。初回はwire本文末尾にlettreが付加するCRLFを期待値へ含めず2件失敗し、固定版の実装確認後に期待wire bytesを修正して全件再成功。専用unit test toolはRust testを検出しないためcargoで実行。変更後のWindows/macOSは未実行。既存native fullのSMTP stepへ自動的に含まれるが、この変更だけのための全OS手動runは起動しない。 |
| SMTP TLS PoC（AC-06） | `cargo test -p mail-client --features smtp-poc --test smtp_candidate --locked`: 13 tests成功。追加8件は暗黙TLS / 必須STARTTLS成功、不可信証明書 / hostname不一致（各方式）、STARTTLS 454 / 未advertise。対象clippy `-D warnings`・format・diff成功。`smtp-poc,imap-poc,security-test`併用のSMTP 13 + IMAP 8 + 汎用TLS 3 = 24 testsも成功。default dependency treeにlettre / webpki-roots / tokio-rustlsなし。Windows/macOS・production buildは今回未実行。既存fullのSMTP stepで実行されるため追加の重い手動CIは起動しない。 |
| SMTP TLS実装時の修正 | lettreがroot provider featureを要求するため`tokio1-rustls-tls`へ修正しlockfile更新。fixtureのSTARTTLS拒否後はclientのQUITへ221を返すよう修正してtimeoutを解消。証明書エラーは`is_tls()`ではなくconnection error内部のrustls InvalidCertificateを確認するよう修正。最終の全関連testsは成功。 |
| SMTP TLS本文送信（AC-12 / 13の前提検証） | `cargo test -p mail-client --features smtp-poc --test smtp_candidate --locked`: Linux arm64で19 tests成功（既存13 + TLS本文6）。対象clippy `-D warnings`成功。TLS接続・認証の既存否定経路も回帰成功。format / diff検査成功。依存・workflowの変更なし。Windows/macOSと本番GUIは今回未実行。既存native fullのSMTP stepに含まれるため追加の全OS手動runは起動しない。 |
| `xvfb-run -a dbus-run-session -- pnpm run test:security:desktop` | 成功。ローカルLinux実WebViewで2 specs pass（iframe isolationとtrusted UI IPCを含む）。 |
| Linux file URL OS-level audit | native run 11で成功。`strace -ff -e trace=%file`がTauri/WebViewを含む88 processを追跡し、一時ディレクトリの合成canaryへのfile syscall 0件。ローカルはstrace未導入のためCIで実行 |
| macOS / Windows file URL OS-level audit候補 | macOS fs_usageのroot観測とdaemonイベント解析はrun 22 arm64で確認。全WebKit coverage / positive controlは未確認。Windows Microsoft Sysinternals Process Monitorはcapture/export・権限・process追跡を含め未実装。AC-05全体の合格には数えない |
| macOS file-access audit harness | `scripts/test-macos-file-access.mjs`でsudoの一時traceを検証し、記録したfs_usage PIDを明示停止。Tauri appの観測を必須とし、fseventsd lstat64以外のcanaryイベントを拒否。生traceは削除。run 24でmacOS ARMの限定分類後の監査成功。全WebKit coverage / positive controlは引き続き未確認 |
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
| SMTP候補の異常系 | final 550、RCPT拒否、lost / truncated final response、暗黙TLS / STARTTLSの証明書不可信・hostname不一致・STARTTLS拒否 / 未advertiseを確認。否定経路の認証0回。TLS上の合成本文送信でも250 / 550 / 応答消失を確認。Outbox unknown / 再起動復旧、本番adapterは未確認 |

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

- macOS ARM / webviewはrun 24で成功したため、同じ確認のために再実行しない。次は必要に応じて最新mainで`macos-15-intel / webview`に絞ってIntel側の修正を確認する。旧runのRe-runではなくRun workflowを使い、節目に`all / full`を実行する。warm cache短縮効果の計測だけを目的とする追加runは不要。macOSの全WebKit process coverage / positive control、Windows Process Monitorの合成canary PoC、対象最低OSの実機試験も必要。
- OS別SecretStore lock / access-deniedを試験し、実IMAP/SMTP実装後はAC-06契約をprotocol adapterへ接続する。
- ADR-006のPoCを基にPhase 07で正規化version、FTS同期、短いqueryのscope付き制限検索、100k性能計測を実装・検証する。
- ADR-002のasync-imap候補はIDLE cancellation / TLS transportのgateを通すまで採用確定しない。
- SMTPのTLS / STARTTLS接続・認証・合成本文送信はローカルPoC成功。MIME候補・制限adapter・stream上限・非同期deadline / cancellation・文字コード / 重複CID診断は38 tests確認済み。復号後100MiBはunit budget計算と実EMLのcharset展開で境界前後を検証済み。通常・inlineのbase64添付25MiB境界と、quoted-printable添付messageの3段解析上限・超過時Incompleteも確認。未知本文charsetとU+FFFDの存在は診断可能になったが、全変換損失や不完全解析の網羅的検出、解析中の資源消費制限は未解決。次はその診断範囲と資源制限を評価する。lost response PoCを本番の再送判断へ直接流用せず、Phase 05で永続Outboxの送出境界・unknown・明示再送契約へ接続する。
