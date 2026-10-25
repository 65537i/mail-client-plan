# ADR-003: HTML本文の隔離PoC

- 状態: 暫定。Linux file-access syscall監査は成功。macOS監査はrun 22でOS daemonのmetadata参照を検出し、限定的な分類を追加（変更後のmacOS再検証待ち）。WindowsはProcmonの動的exact-path filter / positive・negative controlを実装したが、UI AutomationとWindows runtimeは未検証。全process coverageは未証明
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

- Run 87（`4f75cec`、all / full）はWindows baselineのProcmon PMLが273,341,060 bytesとなり、256 MiB上限を4,905,604 bytes超過して失敗。baseline UI specは通ったが、CSV export / canary分類前に停止し、attack captureは未実行。従ってSystem eventの有無について証拠は得られていない。Windows以外の3 runnerは成功。PML上限や全system event観測を弱めて成功扱いにしない。
- Run 87後に、canary / positive-controlの完全一致Path Include条件だけを設定した`.PMC`をUI Automationで生成し、`/LoadConfig`でcaptureするPoCへ変更。Drop Filtered Eventsを有効化し、capture中にNode positive-controlと別sentinelをreadして、positive ReadFileの保存とsentinelの非保存を検証する。CSVの対象外path、canary event、control欠落、設定・load失敗はすべて拒否する。ProcmonのTauri / WebView2一般活動観測は要件から外し、WDIO実WebView成功を独立証拠とする。対象pathの全process / operation event判定、256 MiB上限、System例外なしを維持する。この実装のUI Automation・`.PMC`再読込・容量改善は未検証で、AC-05達成には数えない。
- Run 86（`4f75cec`、Windows / full）でwrite-through生成後の監査成功。baseline / attackとも44-byte canaryをcapture前にsync / closeし、control ReadFile 1件・canary event 0件。baseline 1 spec / attack 2 specsとHTTP 0 requestsも成功。PMLは145,440,481 / 154,757,518 bytes、CSVは56,857,312 / 61,445,045 bytes。既存の全process拒否・無filter・256 MiB上限を維持した成功だが、変更前にもRun 81成功例があるため単一比較で因果関係を確定しない。最新commitのall / fullと完全なdescendant coverageは未確認。
- Run 84後の比較変更はcanary生成にO_SYNCを指定するもの。[固定Node 24.22.0のlibuv実装](https://github.com/nodejs/node/blob/v24.22.0/deps/uv/src/win/fs.c)ではFILE_FLAG_WRITE_THROUGHへ変換される。44-byte内容、排他作成、明示sync / closeは維持し、生成完了UTCとサイズをcapture前に確認する。遅延したcanary生成処理という仮説を調べるもので、write-throughでもmetadataや他のOS処理が残る可能性があり原因解明・再発防止を保証しない。Linux回帰31件成功、Windows runtime未実施。待機時間の水増し、buffered fallback、System例外やpre-start event除外は追加しない。
- Run 84（`8eb9b8a`、Windows / full）はbaseline / attackともSystem canary 3 eventsで失敗。Resultは全てSUCCESS、DetailはEndOfFile: 44 / SyncType: SyncTypeOther / 空。時刻はbaseline 19:40:38.445、attack 19:40:53.473 UTCで、それぞれWDIO start送信より約1.44 / 1.21秒前。attackのfixture注入より約6.89秒前で、このrunのeventはfixture注入後に起きたものではない。canary生成時の遅延処理は調査仮説であり、原因確定ではない。生成・flush・close側を次の調査対象とし、System eventや試験開始前eventを自動的に除外しない。UI全specs / HTTP 0 requests / trace容量gateは通過したが、AC-05合格ではない。
- Run 82後の追加診断はcanary最大10件の時刻 / Resultとallowlist Detailだけを記録する。Detailは非負整数のOffset / Length / EndOfFile / AllocationSize、既知SyncType / PageProtectionに限定し最大8項目、未知項目は伏せた件数だけを返す。capture / WDIO区間のUTCとlocal UTC offsetを併記するが、fixture注入との因果関係はこれだけでは証明できない。未知形式でもeventを落とさず、列数不正のCSVは明示失敗とする。Linux回帰29 tests成功、Windowsの新診断は未実行。
- Run 82（`5f17ae3`、all / full）はUbuntu / macOS両arch成功、Windows失敗。Windows baselineはcontrol 1件 / canary 0件、attackはcontrol 1件 / System canary 3件（SetEndOfFileInformationFile / CreateFileMapping / FASTIO_RELEASE_FOR_SECTION_SYNCHRONIZATION）。両captureのPML / CSVは256 MiB以内で、UI specsとHTTP 0 requestsも成功しており、失敗点はcanary gate。Run 81の成功だけでは解決を示さず、baselineとの差も攻撃起因の証明ではない。次の切り分けではpathや生traceを公開せずevent時刻・Result・限定Detailを調べる必要がある。無条件のSystem例外や成功までの自動再試行は行わない。
- Run 81（`5f17ae3`、Windows / webview）成功。baseline 1 spec / attack 2 specs、HTTP 0 requests。両captureでNode ReadFile control 1件、canary event 0件、Tauri / WebView2観測を確認。captureは15,073 / 13,578 ms、PMLは145,097,190 / 157,696,343 bytesで既存256 MiB上限内。System例外やfilterは追加していない。この実行での成功を過去のSystem eventの原因特定、全descendant coverage、最低OS対応、AC-05全体の合格とは扱わない。
- Run 79後はWDIOのmodule importを子Nodeでcapture前に行い、readyの後にProcmonを開始する。Launcher構築・runとTauri / WebView起動はcaptureと別ファイルのNode ReadFile control確認後に限定する。cmd / pnpm / PowerShellのcold startupを記録区間から外すが、filter、256 MiB上限、Systemを含む全processのcanary拒否条件は変更しない。親は失敗時に待機workerも終了させ、一時traceを削除する。時間と記録byte数を診断表示する。Windows上の容量削減とSystem eventへの影響は未検証。
- Run 78（`fbb335a`、all / full）はmacOS両arch成功。Windowsはbaseline / attackともpositive-control ReadFile 1件、System canary event 3件（SetEndOfFileInformationFile / CreateFileMapping / FASTIO_RELEASE_FOR_SECTION_SYNCHRONIZATION）で失敗。同じevent列だけでは原因を断定しない。Run 79（同commit、Windows / webview）はbaseline UI spec成功後、PMLの256 MiB上限超過でexport前に停止。attack未実行のため、System eventの再現証跡ではない。system-wide captureの記録量制御とSystem eventの帰属は別の未解決事項で、上限・canary拒否gateは維持する。
- Windowsはbaseline / attackを別々のProcmon captureで比較する診断を追加した。baselineではcanaryを作成するがURLをWDIOへ渡さず、専用configで既定UIを1.5秒観測するだけとし、攻撃fixtureと通常security specsは実行しない。attackでは従来のsecurity specsを維持。各captureでpositive controlとTauri / WebView2観測を必須とし、両方のイベント数と最大10件のoperation / process名を報告する。baselineにcanary eventがあってもcapture自体が成立していればattackを実行し、最終gateはbaseline / attack両方のcanary event 0件。Systemイベントの例外化やbaseline差分の減算は行わない。別起動・別canary・異なる所要時間とcache状態のため、背景処理の因果関係を確定するものではない。実Windows runnerでの比較は未実施。
- Run 76でmacOS positive controlのopenは記録されていたが、`fs_usage -w`のprocess末尾thread IDをPIDと比較して拒否していたことが判明。[fs_usage manual](https://keith.github.io/xcode-man-pages/fs_usage.1.html)に従い、固有control pathへのopen/readと`node.<thread ID>`を確認するよう修正。別のNode processのidentityを独立検証するものではない。WindowsはSystem event 3件が残り、control分離だけでは解消していない。Systemの例外allowlistは追加せず監査失敗を維持する。
- これはPoC UIであり、sanitizer、MIME parser、CID変換、リンク一覧UIを実装していない。
- `srcdoc` CSP、CSP継承、sandbox動作はrun 9でWKWebView、WebView2を含む4 runnerで確認したが、最低サポートOSの実機証跡は別途必要。
- ACLはmain windowの許可範囲を制限する。iframe単位の権限分離をACLだけで保証したとは扱わない。
- Linux WebDriver実装はsandbox opaque-origin frameへの切替を拒否した。iframe内部DOM・resource completionを直接読む代わりに親DOMからのアクセス拒否、load回数、ネットワークlistenerを確認した。Linuxのcanary file syscall監査は完了したが、Windows/macOSでは別のOS-level計測が必要。
- macOSでは`fs_usage -w -f filesys`がroot権限でファイルシステム活動を観測する。広範囲のtraceを扱うため、実行時に生成する短い固有canary名だけを照合し、生traceをartifact/logへ保存しない。run 22 arm64でsudoの観測権限とdaemonイベントの解析を確認したが、全WebView process coverageは未検証。
- macOS harnessは`sudo -n fs_usage`のsystem-wide traceを一時ファイルに取り、Tauri processの記録を必須とする。独立したNode processに別の固有ファイルを同期readさせるpositive controlも記録し、`node.<PID>`のopen/readがtraceに現れなければ監査失敗とする。run 74では旧`cat` controlを両archで観測できなかった。生traceがないため原因は未確定で、reader変更後のruntime検証が必要。欠落時はmatching event数と最大10件のoperation / process-threadだけを診断し、生pathは公開しない。攻撃canaryへの予期しないイベントは失敗を維持し、`fseventsd`の`lstat64`のみ別集計する。生traceはartifact/logへ出さず、実行後に削除する。全WebKit process coverageは未検証。
- run 20ではmacOS arm64成功、IntelはWebViewの2 specs成功後にcanary名検出で失敗した。system-wide traceの文字列検出だけではWebViewに帰属できず、元traceは削除済みのため実アクセス元は不明。監査終了がWDIO終了の約76秒後だったため、sudo wrapperではなく記録したfs_usage PIDへ権限付きSIGINTを送るよう修正した。canary検出時の失敗条件を維持し、operation / process-thread名のみを最大10件表示する。修正後のmacOS再実行・coverage検証は必要。
- run 22 (`ef6259d`) のmacOS 14 arm64は2 specs成功、HTTP 0件。停止修正後はWDIO終了13:32:35から判定13:32:36まで約1秒。失敗の内訳は`operation=lstat64 process/thread=fseventsd.2298`の1件で、WebViewではなくOSのファイル変更監視daemonによるmetadata参照を検出していた。
- 利用者の確認を受け、`lstat64`かつprocess/thread欄が`fseventsd.<数値>`のイベントだけを別集計し、成功時も件数を表示する。open/read等、別process、未知formatのcanary検出は失敗を維持する。複数イベントの混在でも失敗を隠さず、生path / traceは公開しない。この限定分類は全システムのcanaryイベント0件を意味しない。traceのprocess名は実行ファイルidentityの証明ではなく、追加したpositive controlのmacOS runner上の観測と全WebKit process coverageは未実証。run 20 Intelのアクセス元をこの結果から推定して確定しない。
- WindowsではMicrosoft Sysinternals Process Monitor（[公式資料](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)）を用いるCI PoCを追加した。workflowは公式配布ZIPから取得し、実行前にMicrosoft Authenticode署名を検証する。試験は短いsystem-wide `/NoFilter` captureを一時PMLへ記録し、Process MonitorのCSV exportから固有canary pathだけを照合する。生PML/CSVはartifactやログへ出さず、実行終了後に一時ディレクトリごと削除する。別ファイルに対するPowerShellの明示ReadFileをpositive controlとし、Tauri appとWebView2 processの観測、および全processからの攻撃canary event 0件を要求する。失敗時もcanary pathやtrace内容は出力しない。run 74でcapture/exportには到達したが、canary eventの検出により監査失敗。process tree coverageは未証明で、AC-05合格の証拠には数えない。Procmonの全system-wide eventを一時記録する方式のため、ローカル手動環境での利用は避け、専用hosted CI環境でのみ実行する。
- Windows run 74は署名検証・Procmon 4.12 capture/exportに到達したが、System processの攻撃canary event 7件で失敗。攻撃canaryとcontrolを共用しており、副作用か攻撃由来かを確定できない。攻撃canaryのwriteをcapture開始前にfsync/closeし、control readには別ファイルを使うよう修正。攻撃canaryのSystem / PowerShell eventも無条件に拒否する。controlファイルのeventは別に扱い、PowerShell ReadFileの観測だけをpositive controlとする。この分離後のWindows runner検証は未実施。
- 3OSでAC-05の全攻撃を検証し、fileアクセスも含む観測方法を定めてから最終決定する。
- SecretStoreの選定とsave/lock/reject/deleteはADR-004で別途検証する。

## 再評価条件

いずれかのWebViewでCSP / sandboxに差異がある、script/通信/navigationが到達する、またはsanitizerの設計に影響する場合は、平文表示を既定に維持し、方式を再評価する。
