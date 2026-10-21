# ADR-003: HTML本文の隔離PoC

- 状態: 暫定。Linux file-access syscall監査は成功。macOS監査はrun 22でOS daemonのmetadata参照を検出し、限定的な分類を追加（変更後のmacOS再検証待ち）。WindowsでのOS-level直接観測は未実装
- 決定日: 2026-10-20

## 背景

メール本文のHTMLは送信者が制御する未信頼データであり、トップレベルDOM、Tauri IPC、外部ネットワーク、ローカルファイルへの到達を許可しない。AC-05は3OSの実WebViewでscript、IPC、外部通信、file読取、トップ画面遷移がすべて0回であることを要求する。

## 選択肢

- 未信頼HTMLをトップレベルDOMへ挿入する: DOMとアプリ権限を共有するため不採用。
- 平文のみ表示する: 安全な初期表示として採用可能だが、HTML表示のPoCにならない。
- 未信頼HTMLをsandbox iframeへ隔離する: PoCとして選択。

## 決定

- 合成fixtureは`srcdoc`のiframeだけに渡し、`sandbox`を空にする。scripts、same-origin、forms、popups、downloads等の例外権限を追加しない。
- PoC用iframe文書の先頭へCSPを追加し、default、script、connect、image、font、media、frame、object、form、baseの各sourceを拒否する。レイアウト確認用のinline styleのみを許可する。
- アプリCSPの`frame-src`は`self`とする。現在のPoCは埋め込み`srcdoc`だけを使い、remote URLを読み込まない。
- `security_probe`は固定文字列を返す副作用のないPoC commandとする。`AppManifest::commands`で登録して生成permissionを作り、main window capabilityだけに`allow-security-probe`を付与する。Tauriのアプリcommand permissionには`app:` prefixを付けない。
- `security_probe`、WebdriverIOの両Rust plugin、frontend plugin、global Tauri API、WebDriver capabilityは`security-test` feature / configに限定する。通常buildではcommand登録もpermission生成も行わない。
- fixtureからのIPCは実WebView未確認。現実装ではiframeのscript実行自体を禁止し、IPCに依存しない遮断を優先する。
- 実製品ではRust側のallowlist sanitizerを別途必須とし、このfixtureを本文表示経路へ接続しない。CID、リンク操作、制御済み画像は未決定。

## 実験条件と結果

| 確認 | 結果 |
|---|---|
| Vue/TypeScript production build | 成功 |
| Rust format / test / clippy | 成功。Rust testは0件。default / `security-test` feature双方をclippy |
| Tauri production native build | Linux arm64で成功。`check-production-security`がWDIO dependency、permission、global API markerの不在を確認 |
| Tauri test native build | Linux arm64で成功。test-only AppManifest ACLとWDIO pluginを含む |
| Linux real WebView | WebKitGTK 2.50.6、Tauri 2.12.4。WDIO 9.31.9 + Tauri service 1.5.0 embedded providerで試験 |
| HTML script / IPC marker | fixtureからのpostMessageなし。攻撃fixture scriptは実行されず、iframe側IPC試行も未実行 |
| 外部HTTP通信 | loopback listenerで観測したfixture由来request 0件 |
| top navigation / iframe境界 | main document URL / title不変、iframe loadは1回、parentの`contentDocument`アクセスは不可 |
| main-window IPC | 明示permission付き`security_probe`をtrusted main UIから呼び出し成功 |
| file URLを含むHTML | 合成canaryへのmeta refresh / image probeを含む。run 9では全4 runnerでiframe再navigationなし。run 11のLinux syscall監査ではcanary pathへのfile syscall 0件 |
| Windows / macOS WebView | run 9でWindows 2025 x64、macOS 14 arm64、macOS 15 Intelの実WebViewにてscript / HTTP / navigation / iframe境界を確認。OS-level file access直接観測は未実施 |
| Linux file-access syscall監査 | GitHub Actions native run 11で、合成canaryを含むWebView試験を`strace -ff -e trace=%file`下で実行。実Tauri appを含む88 processでcanary pathへのfile syscall 0件 |

Linux PoCの結果はこの環境のWebKitGTKに限る。AC-05全体の合格やsanitizer不要の根拠にはしない。ローカルHTTP probeのrequest countとWebView navigation / top DOM変化 / IPC結果を確認し、Linux CIではOS syscall監査で合成canaryへのアクセス試行が0件であることを確認した。

## 制限と次の検証

- これはPoC UIであり、sanitizer、MIME parser、CID変換、リンク一覧UIを実装していない。
- `srcdoc` CSP、CSP継承、sandbox動作はrun 9でWKWebView、WebView2を含む4 runnerで確認したが、最低サポートOSの実機証跡は別途必要。
- ACLはmain windowの許可範囲を制限する。iframe単位の権限分離をACLだけで保証したとは扱わない。
- Linux WebDriver実装はsandbox opaque-origin frameへの切替を拒否した。iframe内部DOM・resource completionを直接読む代わりに親DOMからのアクセス拒否、load回数、ネットワークlistenerを確認した。Linuxのcanary file syscall監査は完了したが、Windows/macOSでは別のOS-level計測が必要。
- macOSでは`fs_usage -w -f filesys`がroot権限でファイルシステム活動を観測する。広範囲のtraceを扱うため、実行時に生成する短い固有canary名だけを照合し、生traceをartifact/logへ保存しない。run 22 arm64でsudoの観測権限とdaemonイベントの解析を確認したが、全WebView process coverageは未検証。
- macOS harnessは`sudo -n fs_usage`のsystem-wide traceを一時ファイルに取り、Tauri processが記録されたことと、後述の限定的分類以外にcanaryイベントがないことを検査する。生traceはartifact/logへ出さず、実行後に削除する。限定分類追加後のmacOS実行は未検証。
- run 20ではmacOS arm64成功、IntelはWebViewの2 specs成功後にcanary名検出で失敗した。system-wide traceの文字列検出だけではWebViewに帰属できず、元traceは削除済みのため実アクセス元は不明。監査終了がWDIO終了の約76秒後だったため、sudo wrapperではなく記録したfs_usage PIDへ権限付きSIGINTを送るよう修正した。canary検出時の失敗条件を維持し、operation / process-thread名のみを最大10件表示する。修正後のmacOS再実行・coverage検証は必要。
- run 22 (`ef6259d`) のmacOS 14 arm64は2 specs成功、HTTP 0件。停止修正後はWDIO終了13:32:35から判定13:32:36まで約1秒。失敗の内訳は`operation=lstat64 process/thread=fseventsd.2298`の1件で、WebViewではなくOSのファイル変更監視daemonによるmetadata参照を検出していた。
- 利用者の確認を受け、`lstat64`かつprocess/thread欄が`fseventsd.<数値>`のイベントだけを別集計し、成功時も件数を表示する。open/read等、別process、未知formatのcanary検出は失敗を維持する。複数イベントの混在でも失敗を隠さず、生path / traceは公開しない。この限定分類は全システムのcanaryイベント0件を意味しない。traceのprocess名は実行ファイルidentityの証明ではなく、全WebKit process coverage / positive controlの実証も引き続き必要。run 20 Intelのアクセス元をこの結果から推定して確定しない。
- WindowsではMicrosoft Sysinternals Process Monitor（[公式資料](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)）がファイルシステム活動の取得・filter・loggingを提供する候補となる。hosted runnerでの権限、CLIによるcapture/export、WebView process descendantsの追跡、およびログからのcanary path判定は未検証。
- 3OSでAC-05の全攻撃を検証し、fileアクセスも含む観測方法を定めてから最終決定する。
- SecretStoreの選定とsave/lock/reject/deleteはADR-004で別途検証する。

## 再評価条件

いずれかのWebViewでCSP / sandboxに差異がある、script/通信/navigationが到達する、またはsanitizerの設計に影響する場合は、平文表示を既定に維持し、方式を再評価する。
