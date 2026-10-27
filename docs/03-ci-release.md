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

Run 310（`536f6d9`、manual Windows 2025 / webview）はsecurity-test build、WebView tests、Windows audit setup / worker、configuration-export regressionを通過した後、`wait-reloaded-filter-menu`で失敗した。Reload後Filter UIA itemは一意で、rectangle中心の`FromPoint` runtime ID一致、foreground一致を確認してpointer inputを送信したが、menu scanは`windows:1;menus:0;visible:0`、focusは`Window:Other`で、メニューは観測されなかった。同じpointer経路の反復は行わず、証明可能な新しいProcmon activation surfaceが得られるまで追加入力はfail-closedとする。正確なreload rules / Drop state / capture / canary / attack判定は未到達でAC-05未達。

Run 311（`bffcccb`、Ubuntu 24.04 / basic）はsuccess。Windows auditに関する証拠ではない。Run 310後、Procmon packageの埋め込みmenu labelsを調べ、Filter dialogの`Ctrl+L`とEvent > Filterサブメニューを次の根拠ある経路として特定した。この時点の次run計画はforeground確認後にFilter dialog shortcutでreloaded exact rulesを読み、`Alt+V`でEvent menuを開き、Procmon所有の一意なFilter submenuとDrop itemを確認することだった。既存のsame-process menu / exact-rule / Drop checked-state gateを維持し、shortcutまたはUIA patternが観測されなければ停止する。pointer fallbackは撤去。関連Windows監査Node regression 43/43、JS syntax / diff checkはlocal成功、PowerShell 5.1 / Procmon runtimeは未検証でAC-05未達。Run 313での実際の結果は次項に記録する。

Run 312（`8358ef5`、Ubuntu 24.04 / basic）はsuccess。Run 313（same commit、manual Windows 2025 / webview）はsecurity-test app build、WebView security tests (step 27)、Windows audit setup / worker (step 28)、configuration-export regression (step 29)を通過したが、Procmon audit (step 30) は`read-reloaded-filter-rules`で失敗した。Ctrl+L後にProcmon所有Filter dialogをembedded-windowとして検出し、layoutは4 ComboBox / 1 Editだったが、UIA scanで64行に達してbounded limitに停止した。正確な2 ruleの検証前で、Alt+V / Drop reload状態 / capture / canary / attack判定には未到達。AC-05未達。

Run 313後の仮説として、同一ProcessId内にdialog外rowが混在している可能性を考え、Run 315（`d855c32`、manual Windows 2025 / webview）でdialog HWND境界を追加した。Run 315もstep 30の`read-reloaded-filter-rules`で停止したが、診断はdialog-window-rows 67 / other-window-rows 0 / unscoped-rows 0を示し、全row候補が同じdialog HWND内だった。UIAには4 List、1 DataGrid、41 ListItem、26 DataItemが見えたため、HWND境界だけではrule rowを識別できないと判明。正確なreload rules、Alt+V、Drop state、capture、canary / attack判定は未到達でAC-05未達。

Run 314（`d855c32`、Ubuntu 24.04 / basic）はsuccess。Windows auditに関する証拠ではない。次の限定試行ではUIA rowを最寄りのList / DataGrid / Tableごとにgroup化し、ComboBox配下のoption rowsを除外する。Include / Exclude actionを持つ一意のcontainerの全行だけをfilter rulesとして渡し、未分類row・複数container・不一致はfail-closedのままにする。診断はbounded countsのみ。関連Windows監査Node regression 43/43、JS syntax、diff checkはlocal成功だが、今回のPowerShell変更は未実行でAC-05の証拠ではない。

Run 316（`904cc72`、push / Ubuntu 24.04 / basic）はsuccess。Windows UIA / Procmon監査の証拠ではない。Run 317（same commit、manual Windows 2025 / webview）はsecurity-test build、実WebView security tests、Windows audit setup / worker、configuration-export regressionを通過したが、step 30の`verify-reloaded-filter-rules`で失敗した。UIAは一意のrule containerを識別し、26行を返した。対象canary / controlの正確なPath/is/Include行は各1行だったが、残り24行があるため、exact-two gateがfail-closedで停止した。Alt+V、reloaded Drop state、capture、positive-control、canary exclusion、attack判定は未到達でAC-05未達。focused regressionはexact rulesの受理、余分 / excluded / non-exact rulesの拒否、bounded exported-config・wait・inventory確認を通過したが、実Procmon UIの24行の意味は判明していない。余分な行を特定するため、次の限定変更としてpathや任意row文字列を出さず、rule rowのdistinct / duplicate数、ListItem / DataItem数、Include / Exclude数、既知field class別件数を記録する。この診断はexact-two gateを維持し、行の意味が確定して必要な除去・再読込とexact-two確認が終わるまでcaptureしない。関連Node diagnostics tests 28/28、JS syntax、diff checkはlocal成功。PowerShell 5.1 / Procmon runtime未検証。

Run 308（`b2253ea`、manual Windows 2025 / webview）はsecurity-test build、WebView tests、Windows audit setup / worker、configuration-export regressionを通過した後、`wait-reloaded-filter-menu`で失敗した。Filter UIA itemはInvokeのみ利用可能で、pattern ID 10018のLegacyIAccessibleはfalse、Invoke後focusはButton、bounded scanは`windows:1;menus:0;visible:0`。Run 307（同commit、Ubuntu basic）はsuccess。次の限定試行では、Run 157のinitial menu clickとは異なる、reload後Filter toolbar itemを対象とする。unique same-process item、positive onscreen rectangle、center pointでの`FromPoint` runtime ID一致、foreground一致を全て確認した場合のみpointer clickを送り、既存のunique same-process open Menu gateで結果を判定する。座標や任意UI文字列は記録しない。関連Windows監査Node regression 42/42とJS syntax / diff checksはlocal成功、PowerShell 5.1 / Procmon runtime validationは未実施。reload rules、Drop state、capture、canary / attack判定未到達でAC-05未達。

Run 250（`140b9b5`、Windows 2025 / webview）はfocus gateを通過してEnterを一度送ったが`verify-filter-file`で失敗した。保存前・直後・5秒後のtargetはいずれもmissing、PMC候補数0。追加したsafe observationではEnter後のownerは`procmon-main`、FocusedElementは`Button:Other`（offscreen / keyboard-focusable:false）となり、mainへ戻ったことは確認できたが、Saveの実効結果は特定できない。dialog elementはEnter直後からother-processとして読まれた。次runではSave対象のtop-level HWNDがProcmonの同一processに属することを確認し、`SetForegroundWindow`後にforeground HWNDとの完全一致を確認できた場合だけEnterを一度送る。前景化不能なら停止し、再送しない。WindowsのPowerShell export wait / focus regression step、Node 30/30、ローカルPowerShell 7.4.13のfile wait / focus / inventory試験成功。PMC保存・reload / WDIO / capture未到達でAC-05未達。

Run 253（`6a2bc6b`、Windows 2025 / webview）はSave dialogへSetForegroundWindowし、対象HWNDとforeground HWNDの一致・Procmon process ownership・Save control focusをすべて確認した後、Enterを一度送信した。それでも`verify-filter-file`に失敗し、target missing、PMC候補0件だった。したがって前景/フォーカス外れで説明できず、dialogの応答やpath処理を特定する必要がある。Windows PowerShell export wait / focus step、Node 30/30、ローカルPowerShell 7.4.13 regression成功。PMC保存・reload / WDIO / capture未到達、AC-05未達。

Run 255（`e4b6378`、Windows 2025 / webview）はEnter送信直後・5秒後のforeground ownerがProcmon main、同一processの非main dialogが0、other-process windowが1、観測した既知buttonラベルの件数が全て0だった。これによりSave後にProcmon確認/エラーdialogが残る仮説は支持されなかったが、対象path missing・PMC候補0で失敗原因は不明。次runはValuePatternによるfilename設定を置き換え、前景化済みdialogのfilename editにフォーカスしてCtrl+A後、SendKeys用に特殊文字をescapeしたpathを入力し、ValuePattern readbackが完全一致し、Save直前にも同じProcmon dialogがforegroundである場合のみSaveを一度実行する。pathや任意UI文字列を記録しない。workflowと同じNode tests 26/26、JS syntax、diff checkは成功。現在の環境ではPowerShellが利用できず、今回追加したSendKeys escape / focus regressionは未実行のためWindows CIで確認する。AC-05未達。

Run 257（`dfea5f5`、Windows 2025 / webview）はSendKeys filename inputを含むPowerShell export regressionが成功し、設定ファイル検証後にProcmon captureとbaseline WebView / CSV exportまで進んだ。Run255までの`verify-filter-file`停止は越えたが、baseline CSVでNode synthetic-canary positive controlが認識されず失敗した。captureは約14秒、PML 875730 bytes。config reloadがexact-path include filterを有効化したか、またはcontrol eventが異なるprocess / operationとして記録されたかは不明。次runは失敗診断に対象control path event数、Node process event数、Node `ReadFile` event数だけを出す。path・任意process名・CSV本文は記録しない。baseline canary assertionとattack scenario未完了、AC-05未達。trace parserの回帰testをWindows workflow Node stepへ追加し、現行Node regression 37/37、JS syntax、diff check成功。

Run 259（`7862da0`、Windows 2025 / webview）はPowerShell export regressionと、trace unit testを含むWindows Node test stepが成功した。baseline capture後のCSV診断は`control-path-events:0; node-process-events:0; node-readfile-events:0`となり、positive-control checkで停止。Run257で解消したPMC保存未達とは別に、filterのexact path rulesがcaptureに効いていない。現在のUIA ValuePattern.SetValueを使うfilter path入力を変更し、Procmon-owned foreground dialog上でキーボード入力と完全一致readbackを検証した後に各Include ruleを追加する。任意pathやCSV本文は出力せず、AC-05は未達のまま。

Run 261（`79c9c90`、Windows 2025 / webview）はfilenameとfilter pathのkeyboard input gatesを通過し、設定ファイル検証・baseline WebView capture・CSV exportまで進んだが、CSVはheaderのみ（76 bytes）でpositive-control path event / Node process / Node ReadFileは全て0。path editのValuePattern設定だけでなくキーボード入力も試したが解決しなかった。次runでは、生成PMCをDTD禁止・1 MiB上限のXML readerで安全に読み、canary/control exact path値の出現数だけを検証・記録する。pathやPMC本文は出力しない。Windows export regressionとNode test 37/37は成功、ローカルJS syntax / diff check成功。baseline canary assertionとattack scenario未完了でAC-05未達。

Run 263（`ed0428d`、Windows 2025 / webview）はfilter / save gate、出力ファイル待機、およびWindows configuration export regressionを通過した。保存先`.PMC`はreadyだったがheader分類は`other`で、`verify-exported-filter-paths`のXML readerがpath evidence出力前に失敗した。したがって、PMCにcanary/control文字列が存在しないとは結論できない。次runでは1 MiB制限内でUTF-8 / UTF-16LE / UTF-16BEとして読み、形式に依存せず完全一致path値の件数だけを出す。pathやファイル本文は記録しない。positive-control capture・canary exclusion・attack scenarioは未実施でAC-05未達。Run 263のplan、Windows export regression、Node testsは成功し、Windows実監査jobはこの証拠段階で失敗した。

Run 266（`e8cdffb`、Windows 2025 / webview）はformat-neutral PMC evidence gate（PowerShell regressionを含む）を通過し、baseline capture / CSV解析まで進んだが、positive-control path event、Node process event、Node ReadFile eventはいずれも0で失敗した。PMC内のexact path値の存在だけではInclude ruleのactionや`/LoadConfig`後の有効性を証明しない。安全なpath-count summaryをsetup成功時にも出力し、欠落時はcapture前にfail closedする。Run266のattack scenario未実施でAC-05未達。

Run 268（`567ed7e`、Windows 2025 / webview）はfilter path keyboard gateとDrop Filtered Eventsのstate check後、`wait-export-config-dialog`で60秒timeoutした。Export Configuration dialog / PMC保存・path evidence / captureへ到達せず、Run268で追加した成功時path-count summaryは未検証。Windows PowerShell regressionとNode diagnostics / trace testsは成功。filter conditionを緩めず同じ限定runで再試行する。AC-05未達。

Run 270（`a289056`、Windows 2025 / webview）はExport Configurationとbounded path summaryを通過し、PMC内のcanary / control path件数は各1だった。しかしbaseline captureは14,519 ms、PML 900,020 bytesで、CSVはheaderのみ（76 bytes）。positive-control path event、Node process event、Node `ReadFile` eventはいずれも0で失敗した。baseline WDIO specとWindows configuration export regressionは成功したが、attack scenarioへは進んでいない。これによりpath文字列の保存は確認できたものの、Include actionまたは`/LoadConfig`後の有効性は未証明である。filter条件を緩めず、次は再読込後のUI rule stateをsafe/fail-closedに確認してからpositive controlを再実行する。AC-05未達。

Run 270後の作業ツリー変更では、保存直後の同一プロセス状態に依存しないよう、Procmonを終了して`.PMC`を`/LoadConfig`で再読込し、UI Automation上のrule rowsからcanary/controlそれぞれの完全一致Path / `is` / Include条件がちょうど2件あることを照合する。読取行はmemory内で比較し、出力は上限付きの件数だけとする。再読込後の`Drop Filtered Events`も同一processのnative menu / MSAA checked stateで読み取り、onでなければcapture前に停止する。余分なrow、Exclude、異なるrelation、UI構造不明はすべてfail closed。Node / PowerShell regressionは成功したが、この変更のWindows PowerShell 5.1 / Procmon UIA runtimeは未実行であり、次の限定Windows webview runで検証する。AC-05未達。

Run 272（`2d1cf19`、manual Windows 2025 / webview）はplan、security-test build、WebView security tests、Windows audit setup / worker tests、PowerShell export regressionを通過したが、実監査は`find-reloaded-main-window`段階で停止した。PMC出力path件数はcanary / control各1、save focus gatesは成功し、Drop Filtered EventsのMSAA stateはoffからonへ変化した。このstageは`Wait-MainWindow`と続く`$main.SetFocus()`を含んでいたため、停止原因は特定できず、reloaded rule rows、positive-control capture、canary判定、attack scenarioは未実行である。capture開始前のfail-closed停止でありAC-05未達。

Run 274（`54a549a`、manual Windows 2025 / webview）はsecurity-test build、WebView security tests、Windows audit setup / worker tests、PowerShell export regressionを通過したが、filter setupは`wait-export-config-dialog`で停止した。Save dialogのwindow / filename / Save control scanは0件で、PMC保存・reload・captureは未到達。Run268と同じ早期UI検出失敗として記録し、条件を緩めず同じ構成で再試行した。

Run 275（`54a549a`、manual Windows 2025 / webview）はRun272と同じくExport Configuration後に`find-reloaded-main-window`で停止した。PMC path件数はcanary / control各1、save focus gates成功、Drop Filtered EventsのMSAA stateはoffからonへ変化した。追加した`PROC_MON_FILTER_WINDOW_SCAN`行はjob logに存在せず、timeoutか照会例外かを判別できなかった。reloaded rule rows、positive-control capture、canary判定、attack scenarioは未実行でAC-05未達。

Run 277（`629d9d1`、manual Windows 2025 / webview）も`find-reloaded-main-window`で停止した。PMC path件数はcanary / control各1、save focus gates成功、Drop Filtered EventsのMSAA stateはoffからonへ変化した。`finally` window-scan行がないことは、`Wait-MainWindow`がwindowを返した後に同じstage内の`$main.SetFocus()`が失敗した可能性と整合するが、失敗箇所は未確定。reloaded rule rows、positive-control capture、canary判定、attack scenarioは未実行でAC-05未達。次runでは`$main.SetFocus()`に独立stageを設定して切り分ける。

Run 279（`1fa170b`、manual Windows 2025 / webview）はplanとWindows job setupを通過し、PMC export evidence（canary / control path各1）、save focus gates、Drop Filtered EventsのMSAA off→on、Windows audit setup / worker tests、configuration export wait testsを確認した。`Wait-MainWindow`は成功し、`focus-reloaded-main-window` stageで`$main.SetFocus()`が`InvalidOperationException`を起こしたことを特定した。reloaded rules、positive-control capture、canary判定、attack scenarioは未実行でAC-05未達。対処として、再読込windowのHWNDがProcmon process所有であることを確認して`SetForegroundWindow`を呼び、2秒以内にforeground HWND / processの完全一致を必須とするgateへ変更する。実際のforeground gateと後続rule reloadは次の限定runで確認する。

Run 281（`3d51c88`、manual Windows 2025 / webview）はplan、security-test build、WebView security tests、Windows audit setup / worker tests、configuration export wait testsを通過した。PMC export path evidenceはcanary / control各1、save focus gatesは成功し、Drop Filtered EventsのMSAA stateはoffからonへ変化。Run 279で失敗したmain window activationはHWND / process一致を確認するforeground gateで解消し、`reload-main-foreground-gate=passed`を得た。次に`open-reloaded-filter-menu`で停止し、reloaded rule rows / positive-control capture / canary判定 / attack scenarioは未実行。AC-05未達。再読込menu itemのInvokePatternを使わず、UIAの`AccessKey`を`Alt+[A-Za-z]`に限定してSendKeysし、foreground gate後に同一process menuが開いたことを確認する。key文字列は記録せず、形式外値はfail closedとする。

Run 283（`4a34ad5`、manual Windows 2025 / webview）は`wait-export-config-dialog`で停止した。Save dialogのwindow / filename / Save controlsは0件で、PMC保存・reloadは未到達。AccessKey経路を試す前の早期UI検出失敗であり、menu activationの成否は示さない。

Run 284（`4a34ad5`、manual Windows 2025 / webview）はPMC export、save focus gates、Drop Filtered EventsのMSAA off→on、reload main foreground gate、reload menu AccessKey format gateを通過した。`open-reloaded-filter-menu`後も同一processのopen menuを検出できず、reloaded rules / positive-control capture / canary判定 / attack scenarioは未実行でAC-05未達。UIA AccessKeyは安全な`Alt+[A-Za-z]`に限定したが、SendKeysで大文字がShift修飾と解釈される可能性を除くため、小文字へ正規化してから送る。値そのものは出力しない。

Run 286（`ab066ce`、manual Windows 2025 / webview）はPMC export evidence、save gates、Drop Filtered Events state、reload main foreground、reload menu AccessKey format gatesを通過したが、`open-reloaded-filter-menu`で停止した。AccessKeyは小文字に正規化して送信されたが、同一processのopen menuを確認できず、reloaded rule rows / positive-control capture / canary判定 / attack scenarioは未実行でAC-05未達。次runでkey送信とmenu observationを別stageにし、入力処理失敗かmenu UIA未検出かを区別する。

Run 288（`719370c`、manual Windows 2025 / webview）はPMC export evidence、save focus gates、Drop Filtered Events state、reload main foreground、reload menu AccessKey gatesを通過した。`SendKeys`呼出し後に`wait-reloaded-filter-menu`で停止し、同一processのopen menuは見つからず、reloaded rules / positive-control capture / canary判定 / attack scenarioは未実行でAC-05未達。次runはSendKeys直後のfocused control type / bounded name / treeを記録し、入力後のUIA状態を観測する。

Run 290（`acb1203`、manual Windows 2025 / webview）はsecurity-test build、WebView security tests、Windows audit setup / worker、configuration export wait testsを通過し、Procmon監査stepで`wait-reloaded-filter-menu`に失敗した。PMC export evidence（canary / control各1）、save focus gates、Drop Filtered Events state、reload main foreground、menu AccessKey gatesを確認。safe UIA診断ではreload後Filter menuはenabled / onscreenだがkeyboard-focusableではなく、AccessKey送信後もfocused controlは`Window:Other`、treeは`Window:Other > Pane:Other`で、open menuへの遷移を観測できなかった。後続のreloaded rule rows、positive-control capture、canary判定、attack scenarioは未実施でAC-05未達。

Run 289（`acb1203`、Ubuntu 24.04 / basic）は長時間のLinux system dependencies install後、Rust format / test / clippy、frontend type-check/buildまで成功した。native buildとWebView関連stepはbasic modeのためskip。Windows Procmonの再読込・filter条件を証明するものではない。

Run 290の観測を受け、再読込後Filter menuを開く処理をSendKeys AccessKeyからUIA patternへ切り替えた。Run 294でInvoke後のfocused-element ancestryからMenuを得られず、Run 296でProcess Monitor所有window subtreeの走査もMenu 0件。Run 298ではExpandCollapsePatternがなくInvokePatternへfallbackしたがMenu 0件で、Run 300ではdesktop root direct-child Menuも合わせて走査してなおMenu 0件だった。Run 302ではSelectionItemPatternも非対応（ExpandCollapse=false、SelectionItem=false、Invoke=true）で、Invoke後focusはButton、bounded UIA scanは`windows:1;menus:0;visible:0`のままだった。Run 302の診断ではinitial Filter menuのDrop Filtered Events off→onを確認したが、reload後状態には到達していない。export path evidenceはcanary/control各1だが、header classification `other`はPMC ruleの証明ではない。Run 304はmain windowのMSAA `OBJID_MENU`にchildren 0件を返し、UIA Filter itemのancestryがToolBar以下であることも確認した。Run 306はstatic LegacyIAccessible型probeでRuntimeExceptionとなったが、Run 308の`AutomationPattern.LookupById(10018)` probeは成功しLegacyIAccessible=falseを記録した。Run 308でもInvoke後focusはButton、same-process bounded UIA menu scanは0件で`wait-reloaded-filter-menu`に停止。正確なrules、reload Drop state、capture、canary/attack判定には未到達。これまでのpatternとaccess-key試行から新しい裏付けのない入力方式は追加せず、Procmon上のsupported automation経路を確認するまでfail-closedとする。Run 302、304、306、308のWindows audit regression / WebView / configuration-export checksは通過、Run 308のProcmon auditのみ失敗。ローカルにpwshがなく、PowerShell regressionの独立したlocal実行は未実施。reloaded exact rules、positive-control capture、canary exclusion、attack scenarioが全て確認できるまではAC-05未達。

Run 292（`1bdb53d`、manual Windows 2025 / webview）はsecurity-test build、WebView security tests、Windows audit setup / worker、configuration export wait regressionを通過したが、Procmon監査で`walk-to-open-filter-menu`に失敗した。初回Filter menuは同一process / enabled / onscreenでInvokePatternを公開し、Invokeも実行されたが、直後のFocusedElementはToolbarで、UIA親treeからopen Menuを確認できなかった。今回のreload後menu InvokePattern経路には未到達。即時focused-control観測を最大5秒のbounded pollへ変更し、same-process Menuだけを受理する。期限内に見つからない場合はfail-closed。reloaded exact rules、positive-control capture、canary判定、attack scenarioは未実施でAC-05未達。

Run 294（`e5b2db9`、manual Windows 2025 / webview）はsecurity-test build、WebView security tests、Windows audit setup / worker、configuration export wait regressionを通過。初回Menuは同一process ownershipを確認し、Filter commandの検出を通過した。reload main foregroundとreload menu InvokePattern gateも通過したが、Invoke後のFocusedElementはButtonで、treeはButton > Window > Window > Paneとなり、focused-element ancestryからはopen Menuが得られず`wait-reloaded-filter-menu`で停止した。reload menuのInvokePatternが呼ばれたこととmenu open状態は別であり、exact reloaded rules / positive-control capture / canary判定 / attack scenarioは未実施でAC-05未達。次runではfocused-element ancestryに依存せず、Process Monitor所有top-level windowを上限128、menu候補を合計256以内で走査し、唯一のenabled / onscreen Menuだけを最大5秒pollして受理する。0件または複数ならfail-closed。

Run 296（`5d7e5e3`、manual Windows 2025 / webview）はsecurity-test app build、WebView security test (step 27)、Windows audit setup / worker (step 28)、configuration export regression (step 29)が成功した。Procmon監査 (step 30) は`wait-reloaded-filter-menu`で停止。bounded diagnosticsではProcess Monitor owned top-level window 1件、UIA Menu候補0件、visible Menu 0件。exact reloaded rules、positive-control capture、canary result、attack scenariosは未到達でAC-05未達。次runは初回menuと同じExpandCollapsePatternを優先し、使えない場合のみInvokePatternへfallbackする。pattern availabilityとmenu scan countを記録し、開いたmenuが一意に確認できなければfail-closed。

Run 298（`772df8b`、manual Windows 2025 / webview）はRun 296と同じくsecurity-test app build、WebView security test、Windows audit setup / worker、configuration export regressionを通過した後、`wait-reloaded-filter-menu`で停止した。reload Filter controlはExpandCollapsePatternを公開せずInvokePatternだけを公開し、Invoke後のbounded scanはProcess Monitor window 1件、Menu 0件、visible Menu 0件と報告した。reloaded rulesやcaptureには到達していない。次runではUIA desktop root直下のMenu候補もsame-process / enabled / onscreenで走査し、window subtreeの候補とruntime IDでdeduplicateする。件数上限と唯一候補条件を維持し、未確認時はfail-closed。

Run 300（`f684eff`、manual Windows 2025 / webview）はsecurity-test app build、WebView security test、Windows audit setup / worker、configuration export regressionを通過した後、`wait-reloaded-filter-menu`で停止した。UIA direct-child MenuとProcess Monitor window subtreeの両方を走査したがMenu候補は0件、Invoke後focusはButtonだった。exact reloaded rules、positive-control capture、canary result、attack scenariosには到達せずAC-05未達。次runはReload Filter MenuItemのSelectionItemPattern対応を記録し、存在する場合のみSelectで開くことを試す。process、enabled / onscreen、unique Menu gateは維持する。

Run 295（`5d7e5e3`、push Ubuntu 24.04 / basic）はsuccess。CI planningとUbuntu basic validationは通過したが、Windows / WebView / Procmon監査の証拠にはならない。

Run 299（`f684eff`、push Ubuntu 24.04 / basic）は確認時点で実行中。push時のbasic scopeであり、Windows Procmon gateとは独立している。

Run 297（`772df8b`、push Ubuntu 24.04 / basic）はsuccess。Windows UIA / Procmon audit evidenceではない。

Run 291（`1bdb53d`、Ubuntu 24.04 / basic）は成功し、Linux system dependencies install、Rust format / test / clippy、frontend type-check/buildを通過した。native buildとWebView関連stepはbasic modeのためskip。

Run 248（`a9269d5`、Windows 2025 / webview）はSave focus gateを通過し、Enterを一度送信したが`verify-filter-file`で失敗した。指定pathは保存前・Enter直後・5秒後すべてmissing、PMC候補数も0。Enter直後のdialogとSave controlはsame-processとして取得されたもののoffscreen、待機後の保持elementはother-processだった。保存操作は再送しない。次runはEnter後にFocusedElementの固定control type / allowlist名 / bounded ancestor typeだけを記録し、同時にフォーカスownerを`procmon-main/procmon-other/other-process/no-window/unavailable`へ分類する。任意のUI文字列・path・例外detailは出さない。WindowsのPowerShell export wait / focus regression step、ローカルPowerShell 7.4.13の同試験、Node 30/30は成功。PMC保存・reload / WDIO / capture未到達でAC-05未達。

Run 246（`665f9fd`、Windows 2025 / webview）はfilter設定とDrop Filtered Eventsのstate検証後、保存操作の前に`verify-export-config-path`で失敗した。最初の`HasKeyboardFocus` gateは失敗してEnterへ進まなかったが、直後のsafe diagnostic readbackは`save-focused:true`だったため、UIA focus stateの一時的不一致が疑われる。これは保存失敗ではなく、fail-closed gateでの停止であり、PMC出力・reload / WDIO / captureは未到達。Save elementの同一process / enabled / onscreen / focusable条件を確認しつつ、focus獲得を最大2秒だけpollし、確認できた場合に限りEnterを一度送る。gate結果を`passed/failed`のenumで記録し、pathやUI文字列は出さない。Node 30/30、PowerShell 7.4.13でtransient / absent focus、既存の保存wait / inventory回帰試験、JS syntax / diff check成功。Windows PowerShell 5.1 / UIA runtimeで次の検証を行う。AC-05未達。

Run 244（`1a8382d`、Windows / webview）はSave Invoke後の指定先状態・directory内PMC候補が、保存直前 / 直後 / 5秒後のいずれもmissing / count 0。指定先以外にもPMCは検出されず、別名出力ではない。Invoke後のdialogとSave buttonはsame-process elementながらoffscreen、wait終了後の保持elementはother-processと観測された。クリック相当のInvokeが成功したと判断できる証拠はなく、原因は未確定。UI pattern Invokeを使い続けず、Save buttonへSetFocusし、HasKeyboardFocus=trueを照合後にだけEnterを一度送る。focusが得られなければ操作を止めて安全な状態だけ記録する。対象file・PMC bytes・任意のpath / UI文字列を出力しない。ローカルNode関連30 tests、PowerShell file wait / header classifier、syntax / diff check成功。保存・reload / capture未到達でAC-05未達。

Run 242（`9414d9f`、Windows / webview）はWindows PowerShell 5.1のfile-wait testに成功。実UIAではExport Configurationの保存先入力・readback・Save Invokeまで通過したが、直後のdialogとSave controlは同一processで`offscreen:true`、target fileは即時・5秒後とも`missing`。timeout後に保持elementは`other-process`となった。よって、ボタン操作が有効に保存したが別先へ書いたのか、dialogが保存前に閉じたのか、failed/cancelしたのか未確定。これをUI actionの失敗と断定せず、UI経路変更もしないで測定を追加する。Save前・Invoke直後・bounded wait後にtarget stateとheader class、temporary directory内PMC候補数・header classes・non-PMC件数・truncationのみを出し、PMC bytes / path / filenames / arbitrary UI textを禁止する。対象の先頭8 bytesは`empty/short/mz/xml/other`へ分類し、生bytesは出さない。actual exported PMCの妥当性は後続の`/LoadConfig`とpositive/negative controlsが別途検証する。run間でtargetのfile setがどう変化するか、Windows runtimeで確認する。Node関連・CI tests 30/30、PowerShell 7.4.13/Linux arm64でfile waitとoutput inventory test成功。`.PMC`確認・再読込 / capture未達、AC-05未達。

Run 240（`88d7133`、Windows / webview）はWindows PowerShell 5.1のfile-wait試験（未作成・99 bytes timeout、100 bytes受理、遅延保存、directory拒否）とNode関連試験が成功。実監査では指定pathのreadbackとSave Invokeまで進んだが、file-waitの初回・最終とも`missing`で失敗し、`.PMC`保存 / capture未到達。待機だけでは解消せず、保存後のdialog状態は未記録だった。次の変更はSave buttonへの明示的focus移動、移動後のpath再照合、1回のInvoke後と検証失敗時のsafe state診断。dialog / buttonの有効・表示状態とpath一致だけを出し、raw path / UI text / 例外詳細は出さない。local関連25 tests / JS syntax / diff check成功、Windows runtimeは再検証待ち。待機上限・file下限・fail-closedを緩和せず、自動再保存も行わない。

Run 238（`2f48084`、Windows / webview）はExport Configurationの発見・Invoke、保存dialogとcontrolsの検証、パス入力・Save Invokeまで通過し、直後の`verify-filter-file`で失敗した。未作成 / 100 bytes未満のどちらかは旧診断から特定できない。保存の非同期完了を待てるよう、同じ100 bytes下限を最大5秒・100ms以下間隔でpollし、初回と最終の状態だけを出力する。入力欄のreadbackが指定パスと一致しない場合はSave前に停止。未作成・過小・directory・IOエラーを成功へ変換せず、固定sleepや保存操作の再送は追加しない。期限切れ後は従来どおり監査を失敗させる。

回帰試験はproduction scriptのASTからfile-wait関数だけを読み込み、実ファイルで未作成・99 bytesのtimeout、100 bytesの受理、別runspaceからの遅延作成 / 増加、directory拒否を確認する。Windows CIではharnessと同じWindows PowerShell 5.1で、UIA監査前の独立stepとして実行する。Linux arm64 / PowerShell 7.4.13でこの試験成功、Node関連28 tests / syntax / diff check成功。これはWindowsでの実保存・filter再読込の証跡ではない。

先行するRun 236（`97caac1`）はSave Filter commandのInvokeを通過したが、保存dialog待機で失敗した。[Microsoft公式配布版](https://learn.microsoft.com/en-us/sysinternals/downloads/procmon)のProcmon64メニュー・dialog resourcesを確認し、`Save Filter...`は名前付きfilter用、`.PMC`保存はFile → `Export Configuration...`と判明した。`ProcmonConfiguration.pmc`と`Procmon Configuration (*.PMC)`も同resourcesに存在する。Run234後のFilter menu routeでは目的のfile exportにならないため、File menu内のexact uniqueなExport ConfigurationをInvokeし、same-processのtop-level / embedded Windowに一意の`File name:` Edit / `Save` Buttonがあることを検証する経路へ変更した。この経路はRun238で通過したが、`.PMC`保存確認以降は未達。任意の最初のEditや別processのSave dialogには書き込まない。保存前summaryは`before-save`、失敗時のdialog診断は上限付きcontrol件数のみ。以下の過去runのmenu推測はこの調査で訂正される。

Actions → native → Run workflowで最新のmainを選び、以下を指定する。旧runのRe-run jobsは旧commitを使うため、修正確認には新規実行を使う。

- `target`: `all` / `ubuntu-24.04-x64` / `windows-2025-x64` / `macos-14-arm64` / `macos-15-intel`
- `mode`:
  - `basic`: Rust format / workspace test / clippy、frontend typecheck / build。native release build、起動、protocol、実WebViewは未実行。
  - `webview`: security-test用Tauri build（frontend typecheck / buildを含む）と実WebView / SecretStore試験。Linux `strace`、macOS `fs_usage`、Windows Process Monitorによるfile-access監査を実行する。WindowsはRun 232までに初期MSAA stateからInvoke後の`checked:on`を確認したが、Save Filter command発見がtimeoutした。Alt+F後のfocused MenuItemは取得できたが、正確なmenu item一覧は未取得。保存経路は未完了で、次はallowlisted menu item summaryを確認する。canary event / capacity問題およびprocess coverageも未解決。production build、起動smoke、protocol、Rust workspace test / clippyは未実行。
  - `full`: 従来の全チェック。選択したOSだけのfullは全OSの証跡ではない。

全モードの前にLinuxの短いplan jobでCI選択ロジックとmacOS / Windows trace解析のNode回帰試験を行い、失敗したら重いmatrixを開始しない。選択scopeと部分検証の注意をActions summaryへ記録する。PRと節目の`all / full`で全OSのgateを確認し、basic / webviewの成功を総合検証成功と読み替えない。

Windows監査stepはProcmon captureをbaseline → attackの順に行う。baselineは専用WDIO configで既定UIを観測し、攻撃fixture / canary URLは渡さない。attackは従来の全security specsを維持する。各capture開始前にUI AutomationでcanaryとNode positive-controlの完全一致Path Include条件だけを持つ`.PMC`を生成し、Procmonを`/LoadConfig`で起動する。capture中は別の合成sentinelをNodeで読み、CSVにpositive-controlのNode `ReadFile`があり、sentinelおよび対象外pathがないことを必須とする。全process / operationの対象path eventを保持し、canary event、positive control欠落、想定外path、filter設定・読込失敗、256 MiB上限超過はいずれも失敗。Tauri / WebView2一般活動のProcmon観測は要求せず、WDIO実WebView試験の成功を独立の証拠とする。baselineは攻撃テストの代用でもSystem event除外でもない。raw traceは各capture終了時に削除する。run 87ではbaseline PMLが256 MiBを超え、export前に失敗したためattackは未実行。記録上限超過は監査不成立であり、イベント0件や攻撃遮断の証拠には数えない。Run 222ではtoggle後のpopup HWNDが閉じchecked stateを再確認できなかったが、Run 224、226、228、230、232ではmenu再open後のMSAA state `checked:on`を確認し、この問題を通過した。5 runともSave Filter command探索がtimeoutし、`.PMC`保存・captureは未到達。Run230後のdiagnosticではfocused MenuItemを確認したが、menu contentsは採取されなかった。次はFileとSave Filterのみをsafe label化し、bounded child summaryを確認する。runtime未確認のため、AC-05の成功証拠には数えない。

Run 79後のharnessは、WDIO moduleを子Nodeで事前importしてreadyを待ち、Procmon起動と別control fileへのNode ReadFileを確認してからLauncherを開始する。アプリ起動・WDIO実行・終了処理は引き続きcapture内で行い、record filterや容量上限は変えない。準備 / capture時間とPML / CSV byte数を診断表示する。workerのIPC回帰試験は依存install後のWindows build jobで実行し、依存不要のplan試験には含めない。変更後のWindows runtime・容量削減効果は未検証。

Run 81（`5f17ae3`、Windows / webview）で上記変更後のruntime成功。baseline / attackともcontrol 1件・canary 0件、PMLはそれぞれ145,097,190 / 157,696,343 bytesで256 MiB未満。これは単一runner実行の部分検証で、負荷変動下の容量保証・過去System eventの原因証明・最新commitのall / full成功ではない。

同commitのRun 82（all / full）はUbuntu / macOS両arch成功、Windows失敗。baselineのcanary 0件に対してattackでSystem event 3件を検出した。PMLは137,957,495 / 183,964,349 bytesで上限内。容量改善とcanary eventの解消は別の問題であり、Run 81のwebview成功をfull成功へ読み替えない。モード差が原因と確定したわけではなく、System eventの帰属は未解決。

Run 82後の診断はcanary最大10件のローカル時刻 / Result / allowlist済みDetail（最大8項目）を出す。生Detailは出さず、未知項目は件数だけ表示する。capture開始要求・WDIO開始送信と終了のUTC、およびlocal UTC offsetも記録し、時刻の照合を可能にする。CSV列数不正は監査失敗とする。これは原因調査用で、Systemの除外や失敗gateの変更ではない。新診断のWindows runtimeは未実行。

Run 84ではbaseline / attackのSystem eventがWDIO開始指示より前に発生していた。次の比較ではcanaryをO_SYNC（WindowsのFILE_FLAG_WRITE_THROUGH）付きで排他的に作成し、sync / close後のUTCと生成byte数を記録する。内容は既存の44 bytesを維持し、生成エラー時のbuffered fallbackや固定待機は追加しない。Windows jobではcanary生成試験とworker IPC試験を実行する。write-throughでSystem eventが解消するかは未確認で、全event拒否・無filter・256 MiB上限を維持する。

Run 86（`4f75cec`、Windows / full）は上記変更後に成功。両captureのcontrol 1件・canary 0件、PML 145,440,481 / 154,757,518 bytes、CSV 56,857,312 / 61,445,045 bytesで上限内。単一成功をSystem eventの原因確定・再発防止保証とせず、最新commitのall / fullは別途確認する。

同commitのRun 87（all / full）はUbuntu / macOS両arch成功、Windows baseline PMLが273,341,060 bytesとなり256 MiB上限超過で失敗。baseline UIは成功したが、CSV export / canary分類前に停止し、attack captureは未実行。Windows以外の成功はWindows fullの代替ではない。Run 86のwrite-through成功を否定・裏付けるevent evidenceはこのrunから得られず、容量上限・無filterを維持する。

Run 87後のWindows capture PoCは、UI Automationでexact-path Include条件と`Drop Filtered Events`を`.PMC`へ保存し、`/LoadConfig`で読み込む方式へ変更する。Path条件はcanaryとNode positive-controlだけで、process名・operation条件は加えない。capture中にpositive-controlと、filter対象外のsynthetic sentinelをNodeで読み、CSV解析は二者の結果と全path scopeをfail-closedで確認する。Procmonのapp / WebView2一般活動gateを外し、同一runのWDIO実WebView成功を別証拠とする。ID設定、drop設定、profile loadの有効性はこのPoCではLinuxのソース・CSV回帰試験だけで、Windows UI Automation / capture runtimeは未実行。256 MiB上限、全canary event拒否、Systemイベントの例外なしを維持し、未実証のままAC-05達成とはしない。

Run 89（`a862532`、all / full）ではUbuntu・macOS両archのfull jobが成功。WindowsもProcmon署名確認と全native / protocol / candidate testsに成功したが、Procmon UI Automation filter setupがexit 1で、baseline capture前に停止した。旧harnessはPowerShell出力を破棄していたため失敗stageは特定できない。変更後は機微な詳細を出さず固定stageだけを表示する診断を追加し、次はWindowsのみのwebview/fullでfilter generationから実証する。Run 89をWindows監査成功やAC-05合格に数えない。

Run 91（`d38647f`、Windows / webview）ではsecurity-test build、Procmon署名確認、Windows harness回帰試験が成功した後、file-access testのProcmon filter setupが`find-main-window`で失敗し、baseline capture前に停止した。WDIO実WebView監査およびProcmon captureには到達していない。`MainWindowHandle`だけに依存したwindow検出を避けるため、UI Automation desktop treeでprocess IDが一致するトップレベルwindowを優先検出し、handleをfallbackにする。Run 91はcapture/filter動作の証拠ではなく、AC-05未達。

Run 93（`534b434`、Windows / webview）では同じfilter setupが`find-main-window`を通過したが、`open-filter-dialog`で停止した。Procmon windowを検出できたことと、keyboard shortcutでdialogを開けたことは別に診断する。Run 93もWDIO/captureに到達しておらず、AC-05の証拠ではない。

Run 95（`fe49719`、Windows / webview）ではforeground化とshortcut送信を通過した後、title patternでFilter dialogを検出できず停止した。dialogはProcmon process ID、main windowとは別のtop-level window、`Reset` controlで識別するよう変更する。Run 95はWDIO/captureに到達しておらず、AC-05の証拠ではない。

Run 97（`9d21d13`、Windows / webview）ではdialogの識別条件を広げても`wait-filter-dialog`で失敗した。次はSendKeysに依存せず、UI AutomationでFilter menuと`Filter...` commandをinvokeする。Run 97はWDIO/captureに到達しておらず、AC-05の証拠ではない。

Run 99（`6e57722`、Windows / webview）ではfilter setup child processが60秒timeoutし、進捗markerは`invoke-filter-command`で停止した。modalを開くmenu commandの同期Invokeを避けるため、UIA focus後にEnterで起動する。

Run 103（`d7e61a1`、Windows / webview）も同じprogress markerで60秒timeoutした。command検索・focus・Enter送信の個別完了点が区別できなかったため、進捗tokenを細分化して次runの停止位置を特定する。

Run 105（`208dc20`、Windows / webview）では`find-filter-command`の5秒待機が失敗した。展開済みmenuを含むMainWindow全体検索が戻らないため、子commandの検索範囲をFilter menu elementへ限定した。

Run 107（`209bf9b`、Windows / webview）ではFilter menu element内のcommand検索も5秒で失敗した。SendKeysでmenuを展開してF mnemonicを選択しEnterでcommandを実行する。Run 105 / 107はいずれもWDIO/captureに到達せず、AC-05の証拠ではない。

Run 109（`4d136c7`、Windows / webview）ではF mnemonic選択後も`wait-filter-dialog`で失敗した。次はFilter menu elementへfocusし、先頭commandを選択してEnterを送る。Run 109もWDIO/captureに到達しておらず、AC-05の証拠ではない。

Run 111（`6bb2b95`、Windows / webview）は`focus-filter-menu`で失敗した。このstageはmenuのSetFocus()直前に設定していたが、UIA状態・親control tree・例外型は記録しておらず、失敗原因の確定には至っていない。次は操作方法を推測で変えず、Filter menu itemのenabled / offscreen / keyboard-focusable状態、allowlist済みcontrol type/nameだけの親tree、SetFocus結果の例外型を固定形式で記録する。任意のUIA名、path、例外messageはログへ出さない。Run 111はWDIO/captureに到達しておらず、AC-05の証拠ではない。

Run 113（`4a16035`、Windows / webview）も`focus-filter-menu`で停止した。PowerShell側でUIA診断markerを出していたが、Node harnessの失敗要約はstageだけを表示していたため、CIログから診断値を取得できなかった。後続修正でboolean state、allowlist済み親tree、固定例外型だけを抽出するhelperを追加し、失敗要約に安全な形式で含める。関連Node回帰7/7成功、PowerShell runtime / UIAの実値は次のWindows runで確認する。Run 113はWDIO/captureに到達しておらず、AC-05の証拠ではない。

Run 115（`253853f`、Windows / webview）でUIA診断を取得。Filter menu itemはenabled / onscreenだが`IsKeyboardFocusable=false`で、control tree上はToolbar配下。`SetFocus()`は`Other`例外で失敗した。次はこの実測に基づいてnon-focusable時のSetFocusを省き、ExpandCollapsePatternを優先する。InvokePattern fallbackを含め、利用可能patternを固定形式で出力し、Windows runtimeでmenu展開とdialog遷移を確認する。Run 115はWDIO/capture未到達であり、AC-05の証拠ではない。

Run 117（`ef70a3f`、Windows / webview）はmenu `ExpandCollapsePattern=false; InvokePattern=true`を観測。SetFocusをskipしInvoke後にHOME / ENTERを送ったが、Filter dialogを識別できず`wait-filter-dialog`で失敗した。次はmenu Invoke後 / HOME後 / ENTER後のFocusedElementをallowlist形式で記録し、実際のfocused controlと親treeから操作先を確認する。診断追加後のNode回帰9/9とsyntax / diff checkは成功、Windows PowerShell runtimeは未実行。Run 117はWDIO/capture未到達であり、AC-05の証拠ではない。

Run 119（`9eb8f38`、Windows / webview）はInvoke後とHOME後にFocusedElement=`Menu`（keyboard-focusableなし）、ENTER後に`Other`（keyboard-focusableあり）を観測したが、Filter dialogは開かなかった。次runで直接子controlの内容を取得する。

Run 121（`cfc9319`、Windows / webview）はMenu直下に11 controlがあり、3番目がenabled / onscreen / keyboard-focusableな`Filter...` MenuItemと観測した。HOMEによる先頭選択は使わず、この完全一致MenuItemを一意に特定する方針。

Run 123（`a878d05`、Windows / webview）は`find-filter-command-in-menu`で停止。完全一致名とControlTypeを組み合わせたUIA検索はMenu配下からcommandを返さなかった。次runでは実際に取得できた直接子一覧をTrueConditionで列挙し、完全一致name / typeでcommandを特定してからfocusする。関連Node回帰は9/9成功、Run 123はWDIO/capture未到達のためAC-05の証拠ではない。

Run 125（`6b6afd5`、Windows / webview）は`find-open-filter-menu`で停止。直前の診断からFocusedElement=`Menu`とその子control一覧が読めた一方、次段のFocusedElement再取得で失敗した。次は診断時に得た同じAutomationElement参照を後段に渡して再取得を避ける。Run 125はWDIO/capture未到達でAC-05の証拠ではない。

Run 127（`48a5248`、Windows / webview）はafter-openのFocusedElementが`MenuItem:Other`で、親tree内に`Menu`を観測した。Run 125でFocusedElementが直接Menuだった状態と異なるため、次は取得済みfocused elementからControlView parentを上り、最初のMenuを子列挙に使用する。Run 127はWDIO/capture未到達でAC-05の証拠ではない。

Run 129（`fcf3d08`、Windows / webview）はafter-openのFocusedElementがMenuで、直接子11件も観測したが`find-open-filter-menu`で停止した。後続runで参照の引き渡しを見直す。

Run 131（`163d157`、Windows / webview）はafter-openのFocusedElement=Menuと子control 11件を観測した後、`resolve-open-filter-menu`で停止した。script-scope handoffを試しても解決しなかったため、次はfunction呼び出し元からmutable IDictionaryへ参照とControlType snapshotを書き込む。Run 131はWDIO/capture未到達でAC-05の証拠ではない。

Run 133（`25109db`、Windows / webview）も`resolve-open-filter-menu`で停止した。after-open markerはMenuと11子controlを示すが、script-scope referenceは後段で取得できなかった。次runではhashtable snapshotを使い、Menu解決を再確認する。Run 133はWDIO/capture未到達でAC-05の証拠ではない。

Run 134（`cc24913`、main push）はplanとUbuntu / basicのみ成功し、Windows jobは選択されていない。Run 135（`cc24913`、Windows / webview）はsecurity-test build、Procmon署名確認、audit harness testsを通過したが、UI Automation filter setupが`resolve-open-filter-menu`で停止した。after-open FocusedElementはMenu controlで、直接子11件と3番目のFilter commandを観測したが、WDIO/captureは未実行。hashtable snapshot handoffのどちら側で値が失われるか不明なため、次runはwriter / callerそれぞれのelement presenceとallowlist済みControlTypeのみを固定診断に出す。Run 135はAC-05の証拠ではない。

Run 137（`f06c83d`、Windows / webview）はsecurity-test build、実WebView security spec、audit harness testsに成功した後、`observe-menu-focus`で失敗した。writer側snapshotはelement present / ControlType Menuで、子control 11件も観測された一方、caller側診断markerは出ていない。次runではcaller確認を独立stageにし、例外messageを抑止したままallowlist済み例外種別を記録する。WDIOはProcmon filter setup後のstepで未実行となり、capture/export/control判定にも到達していない。Run 137はAC-05の証拠ではない。

Run 139（`153a08b`、Windows / webview）もProcmon filter setupで失敗。ログ要約にはwriter markerとMenu / 11 child controlsがあるが、caller / failure-type markerはなく、報告stageは最後に観測された`observe-menu-focus`。Node harnessはstdoutの先頭1024文字だけを保持するため、診断末尾が切れた可能性がある。次runは固定形式・allowlist診断のみに限定したまま、収集上限を厳密な4096文字へ増やして後続markerを確認する。Run 139はWDIO/capture未到達でAC-05の証拠ではない。

Run 141（`541365e`、Windows / webview）では4096文字上限下でcaller snapshotもelement present / ControlType Menuと観測し、Filter commandを一意に特定してfocusできた。Enter後のFocusedElementはButtonとなり、filter dialogは見つからず`wait-filter-dialog`で停止した。次runはFilter commandのInvokePattern / SelectionItemPattern対応を固定booleanで観測する。未確認のactivation操作を試さず、WDIO/capture/export/control判定は未到達のまま。Run 141はAC-05の証拠ではない。

Run 143（`9528184`、Windows / webview）はFilter commandのInvokePatternがtrue、SelectionItemPatternがfalseと観測された。キーボードEnter後はFocusedElement=Buttonでdialog未表示のため、次runでは測定済みInvokePatternを呼ぶ。Run 143はWDIO/capture/export/control判定に到達しておらず、AC-05の証拠ではない。

Run 145（`7d8ee5b`、Windows / webview）はFilter commandのInvokePattern呼び出し後も`wait-filter-dialog`で停止した。after-invoke FocusedElementはOther、親treeにWindowが含まれたが、Reset controlを含むdialogは既存のwindow scanで認識されなかった。次runは同process / main以外のroot window数とReset control有無をallowlist済みの数値 / booleanで記録する。WDIO/capture/export/control判定は未到達、AC-05の証拠ではない。

Run 147（`1a8ba42`、Windows / webview）はProcess Monitor所有のroot windowが1つ（mainのみ）、non-main window 0、Reset controlなしと観測し、InvokePattern後もFilter dialogが生成されなかったことを確認した。次runは`TryGetClickablePoint`がtrueの場合だけ、観測済みFilter command上でpointer clickを実施する。クリック点の座標や任意UI文字列はログに出さず、falseなら失敗する。Run 147はWDIO/capture未到達でAC-05の証拠ではない。

Run 149（`d8af080`、Windows / webview）はUIAのafter-open観測ではFilter commandを示したが、後段の直接子要素の再列挙後、`match-filter-command`で失敗した。pointer click前に停止し、clickable-point有無の証拠は得られていない。次runはchild item property read / exact match / match-count validationを独立stageにし、最大9999にboundedした件数のみ記録する。Run 149はAC-05の証拠ではない。

Run 151（`c2ba7fb`、Windows / webview）は11子からFilter command 1件をmatchしたが、count marker出力後に`verify-filter-command-count` stageで停止した。UIA failure typeはallowlist上`Other`で、pattern / clickable-point probe前だった。次runはcommand Current state、pattern probe、clickable point、availability checkを別stage化する。pointer input、WDIO、captureは未実行、AC-05の証拠ではない。

Run 153（`34313de`、Windows / webview）はmenu item read / exact match / command state / pattern probeを通過後、`TryGetClickablePoint`呼び出し中の`probe-filter-command-clickable-point`で停止した。geometry markerは未出力。out Pointを明示初期化しWindowsBaseを参照する変更を次runで検証する。pointer click、WDIO、capture/export/control判定は未実行。Run 153はAC-05の証拠ではない。

Run 155（`26174c6`、Windows / webview）でも明示型Pointを使うTryGetClickablePointは同stageで失敗し、clickable pointを得られなかった。次runはこのAPIを使わず、UIA BoundingRectangleがonscreenかつ幅 / 高さとも正の場合のみ、その中心を使う。座標はログに出さず、不正 bounds は拒否する。Run 155はWDIO/capture未到達、AC-05の証拠ではない。

Run 157（`860358f`、Windows / webview）はonscreenのpositive bounds中心をクリックした後、FocusedElement=ToolBar、main以外window 0 / Reset controlなしとなりdialog未表示だった。座標が対象MenuItemを指していた証拠がないため、次runでは入力前にFromPointのUIA elementと最大4 parentを調べ、完全一致Filter... MenuItemかだけ記録して検証する。click target不一致時はfail closed。Run 157はAC-05の証拠ではない。

Run 159（`daf85b9`、Windows / webview）は11子からFilter commandを一意に特定し、FromPointとControlView parentによってrect中心が同じFilter MenuItemであることを確認した。それでもphysical click後はfocusがOtherへ移り、root windowは同一processのmainのみ、Reset controlなしで`wait-filter-dialog`に失敗。座標誤りではなくpointer activationでdialogが開かなかったことを示す。次runではFilter command自身のInvokePatternを直接使い、一意一致・InvokePattern提供・有効状態を必須とする。以前の親Filter menuに対するInvokePattern試行とは別の対象要素である。Run 159はWDIO/capture未到達でAC-05未達。

Run 161（`0bed283`、Windows / webview）はFilter command自身のInvokePatternを実行したが、dialogは生成されず、同一process root windowはmainのみでReset controlなし。親Filter menuへのInvokeとphysical clickに続き、別のcommand-level UIA activationも失敗した。次runではpost-activation focus windowがProcmon main / Procmon別window / 他processのいずれかをsafe enumで記録し、全desktop root windowsにReset controlがあるかをbooleanで診断する。別process UIは利用せず、設定対象windowは引き続きProcmon所有に限定。Run 161はWDIO/capture未到達、AC-05未達。

Run 163（`61658f2`、Windows / webview）ではFilter command自身のInvokePattern後、focus ownerはProcmonの別windowと判定された。一方、same-process root windowはmainのみで、Reset controlはdesktop root window走査で検出された。Reset controlのroot ownerがProcmon main、Procmon別window、other processのどれかはbooleanでは区別できず、dialogがmain配下か別process配下か未確定。次runはReset所有区分と上位ControlTypeのみ診断し、他processのUIを設定対象にしない。Run 163はWDIO/capture未到達、AC-05未達。

Run 165（`747d074`、Windows / webview）でReset ownerはProcmon main、UIA ancestorは`Button>Window>Window>Pane`と記録された。root scanはmain windowだけを検出していたため、Filter dialogがmain UIA subtreeに埋め込まれたwindowである可能性が高い。次runではmain descendantsからResetを探し、ControlView parentにあるWindowのうちProcmon PID一致・非zero HWND・main HWNDと異なるものだけをdialog候補として返す。process境界とfail-closed条件は維持する。Run 165はWDIO/capture未到達、AC-05未達。

Run 167（`d453245`、Windows / webview）はembedded Window候補を検出し`wait-filter-dialog`を通過、Reset操作後に`set-canary-filter`へ進んだ。しかし選択した最も近いWindow ancestorでは規定の3 ComboBox / 1 Editが見つからず停止。次runはResetを含むWindow ancestorを上方へ探索し、same-process / nonzero / non-main HWNDに加え、Resetと少なくとも3 ComboBox / 1 Editを含むlayoutを満たす候補だけを返す。Run 167はPMC/WDIO/capture未到達、AC-05未達。

Run 169（`eab43b2`、Windows / webview）はResetと4 ComboBox / 1 Editを持つProcmon所有・non-main HWNDのWindow ancestorを選び、`wait-filter-dialog`を通過したが、既存の`set-canary-filter`内で失敗。field/operator/value/action選択とAddのどの操作かログから区別できない。次runでは固定stageを各操作前に記録して failure locationを特定する。Run 169はPMC/WDIO/capture未到達、AC-05未達。

Run 171（`59d4ead`、Windows / webview）は`select-filter-column`と`select-filter-operator`を通過後、SetValueの実行前stage `set-filter-path-value`で停止した。さらにaction ComboBoxの固定index 2にはInclude optionがなかった。次runは全ComboBoxに対して要求optionの存在を個別に調べ、一意に一致したcontrolだけ選択し、Editの状態とValuePattern有無をallowlisted booleanで記録する。Run 171はPMC/WDIO/capture未到達、AC-05未達。

Run 173（`fffed7d`、Windows / webview）はPath / isを固定indexでなく一意option照合により選択し、`set-filter-path-value`付近で失敗した。Editのenabled / offscreen / read-only / ValuePattern状態が未出力のため、次runでその4 booleansを診断し、ValuePattern未提供・field無効・read-onlyは明示拒否する。Run 173はPMC/WDIO/capture未到達、AC-05未達。

Run 175（`79e8d92`、Windows / webview）はEditがenabled / onscreen / writable、ValuePattern提供ありと記録したが、出力が4096文字上限に達して失敗stageが不完全なままとなった。次runでは診断上限を8192へ増やし、上限到達も固定booleanで示す。ログはallowlist済み・boundedを維持し、Run 175はPMC/WDIO/capture未到達、AC-05未達。

Run 177（`ab488e6`、Windows / webview）は8192文字以内にcomplete failure markerを保持し、stageが`enable-drop-filtered-events`と確定した。embedded filter dialogのReset / rules / path value / Applyまでは成功している。後続の`Alt+F`によるDrop Filtered Events切替で停止したため、次runでは既に観測済みのFilter menuをUIA InvokePatternで開き、該当項目とTogglePatternを特定する。Run 177はPMC保存 / WDIO / capture未到達、AC-05未達。

Run 179（`4de93ce`、Windows / webview）はfilter dialog discovery / rule設定 / Applyまで成功したが、Filter menuを開いた後の`find-drop-filtered-events`で停止した。UIA lookupがmain window subtreeを対象にしており、popup menu側の項目を見ていなかった可能性がある。次run向けにFocusedElementから開いたMenuをたどり、same-process・enabled・onscreenを確認後、menu descendantsから`Drop Filtered Events` MenuItemを一意に解決してTogglePatternを検査する変更を実装した。新たなdiagnosticは固定enum / bounded countsのみ。関連Node test 11/11、JS syntax check、`git diff --check`成功。PowerShell / Windows UIA runtimeは未検証で、Run 179時点ではPMC保存 / WDIO / capture未到達、AC-05未達。

Run 180（`b4c9806`、push / Ubuntu 24.04 x64 / basic）は成功した。planとUbuntu basicの証拠であり、Windows / webviewやAC-05の証拠ではない。

Run 181はworkflow dispatchの既定値`all / full`で開始してしまった。plan成功後にUbuntu / Windows / macOS両方のmatrix jobが起動したが、各検査完了前にcancelを要求し、全matrix jobの`cancelled`を確認した。検証証拠には数えない。Run 182（`b4c9806`、Windows 2025 x64 / webview）はpopup menuを同一Procmon processから解決し、一意な`Drop Filtered Events` itemを発見したが、`TogglePattern`が提供されず`probe-drop-filter-toggle`で停止した。Run 184（`7ce682e`、Windows 2025 x64 / webview）も同stageで停止し、追加の統合pattern診断は失敗要約から得られずpattern availabilityを確定できなかった。Run 186（`8921a49`、Windows 2025 x64 / webview）はTogglePattern=false、InvokePattern=true、SelectionItemPattern=falseを取得した後、LegacyIAccessiblePattern probeで失敗した。Run 188（`7fede8f`、Windows 2025 x64 / webview）はItemStatus / HelpTextが`other`で`probe-drop-item-state`停止。次runではFrameworkId enumとnative-window-handle有無booleanだけを調べる。PMC保存 / WDIO / capture未到達、AC-05未達。後続の診断拡張は固定boolean / allowlisted enumのみで、既定UI操作は変更しない。

Run 183（`7ce682e`）、Run 185（`8921a49`）、Run 189（`3eddfa6`）のpush / Ubuntu 24.04 x64 / basicはいずれもsuccess。planとUbuntu basicの証拠であり、Windows / webviewやAC-05の証拠ではない。Run 187（`7fede8f`）のpush / Ubuntu basicは後続pushによりcancelledで、検証証拠に数えない。Run 186後のdiagnostic changeは関連Node test 12/12、JS syntax check、`git diff --check`を通過したが、PowerShell / Windows runtimeは未検証。

[Run 190](https://github.com/65537i/mail-client-plan/actions/runs/40238680455)（`3eddfa6`、Windows 2025 x64 / webview）はpopupの同一process ownershipとunique item検索を通過したが、`probe-drop-item-state`で停止。TogglePattern=false / InvokePattern=true、FrameworkId=Win32、itemのnative HWNDなし / menuのnative HWNDありで、checked stateは未確認。`.PMC`保存 / WDIO / capture未到達、AC-05未達。後続変更ではMicrosoft Win32 [`GetMenu`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmenu)と[`GetMenuItemInfoW`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmenuiteminfow)を使い、Procmon main window内のexact `Drop Filtered Events` menu itemを一意に解決し、[`MENUITEMINFOW`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-menuiteminfow)の`MFS_CHECKED`だけでstateを照合するread-only probeを追加した。全読取が成功し一意にoffと確認された場合だけInvokePatternを一度呼び、再照合でonを確認してから保存へ進む。未知・重複・読取不能はfail-closed。該当runのPowerShell / Win32 runtimeは未実行。

[Run 191](https://github.com/65537i/mail-client-plan/actions/runs/40240259586)（`47d7f10`、push / Ubuntu 24.04 x64 / basic）はsuccess。Windows / AC-05の証拠ではない。[Run 192](https://github.com/65537i/mail-client-plan/actions/runs/40240666463)（`47d7f10`、Windows 2025 x64 / webview）はfilter dialogとUIA item照合後、`probe-drop-native-menu-state`で`RuntimeException`となった。native snapshot diagnosticがなく、PMC保存 / WDIO / capture未到達、AC-05未達。次runで`GetMenu` handle取得、bounded menu scan、state reportを別々のstageにして失敗箇所を限定する。native stateが確認できない場合はInvoke・保存を行わない。

[Run 193](https://github.com/65537i/mail-client-plan/actions/runs/40241556573)（`f37ecf3`、push / Ubuntu 24.04 x64 / basic）はsuccess。Windows / AC-05の証拠ではない。[Run 194](https://github.com/65537i/mail-client-plan/actions/runs/40241654873)（`f37ecf3`、Windows 2025 x64 / webview）はnative menu scan / reportまで到達したが、`verify-drop-native-menu-state`で停止。出力`handle:true|false`がparserの`available|unavailable` allowlistと一致せず、stateおよびDrop itemのenabled / offscreenをdiagnostic summaryで区別できなかった。Invoke / PMC保存 / WDIO / capture未到達、AC-05未達。Run194後はnative handleをallowlist enumへ修正し、Drop itemのenabled / offscreen booleanもdiagnoseする変更を加えた。関連Node tests 12/12、JS syntax check、diff check成功。修正版Windows runtimeは未確認。

native [Run 196](https://github.com/65537i/mail-client-plan/actions/runs/40242593402)（`73169a0`、manual Windows 2025 x64 / webview）はplan成功、Windows job失敗。`probe-drop-native-menu-state`でUIA popup HWNDは得られたが、main windowのWin32 `GetMenu`はnullを返し、native snapshotはhandle unavailable / items 0 / matches 0 / readable false / checked unavailableとなった。fail-closedでInvoke、`.PMC`保存、WDIO、captureは未実行、AC-05未達。後続修正はWin32 [`GetGUIThreadInfo`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getguithreadinfo)からactive menu ownerを解決し、[`GetWindowThreadProcessId`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindowthreadprocessid)でpopupとownerが同一Procmon processに属すると確認した場合に限り、owner HWNDで`GetMenu`を再試行する。取得不能・cross-process・曖昧なmenu itemは拒否を維持する。新しいallowlist診断はHWNDやpathを記録しない。Node diagnostics tests 13/13、JS syntax check、diff check成功。PowerShell / Win32の実Windows runtimeは次runで確認する。

native [Run 198](https://github.com/65537i/mail-client-plan/actions/runs/40244199050)（`c3b1c3b`、manual Windows 2025 x64 / webview）はplanとsecurity-test build成功。Procmon監査setupはcanary flush / close後の`select-filter-operator`で60秒timeoutとなり、ComboBox 4個 / Edit 1個のfilter dialog確認以降、operator option探索の実行箇所を特定できなかった。`.PMC`保存、WDIO、capture / control未到達でAC-05未達。Run196後に追加したmenu-owner fallbackは未実行。次の診断変更はcolumn / operator / actionそれぞれのComboBox候補ordinal、展開、option待機に固定stageを設けるだけで、選択条件やUI操作は変えない。

native [Run 200](https://github.com/65537i/mail-client-plan/actions/runs/40245305319)（`c4f857b`、manual Windows 2025 x64 / webview）はplan、security-test build、Windows audit setup / worker tests成功。`select-filter-operator`を通過してWin32 owner fallbackに到達し、popup / ownerのProcmon process一致とowner `GetMenu` handle取得を確認したが、menu scanはitems 0 / matches 0 / readable falseでstate unavailableとなった。fail-closedでfilter Invoke、`.PMC`保存、WDIO、capture / control未実行、AC-05未達。既存出力ではmenu count invalidと最初のitem read failureを区別できないため、次runでowner-drawn / item-read-failed / invalid count / bounds超過をallowlist診断し原因を特定する。厳格なscan・state判定は維持する。

native [Run 202](https://github.com/65537i/mail-client-plan/actions/runs/40246429963)（`30f7500`、manual Windows 2025 x64 / webview）はplan、security-test build、Windows audit setup / worker tests成功。診断で`GetMenuItemCount`が-1を返すと分かった。Run202後の未検証修正ではnative wrapper内でerrorを即時捕捉し、1401（`ERROR_INVALID_MENU_HANDLE`）/ 0 / その他を`invalid-menu-handle` / `menu-count-invalid` / `menu-count-failed`の固定enumへ写す。生codeやhandleは出さず、全失敗を引き続き拒否する。Node diagnostics tests 13/13、JS syntax checks、`git diff --check`成功。PowerShell / Win32 runtimeとerror分類は次runで検証する。`.PMC`保存 / WDIO / capture / control未到達、AC-05未達。API: [`GetMenuItemCount`](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getmenuitemcount), [`ERROR_INVALID_MENU_HANDLE`](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1300-1699-)。

native [Run 204](https://github.com/65537i/mail-client-plan/actions/runs/40248126925)（`3bc5788`、manual Windows 2025 x64 / webview）はplan、security-test build、WebView security tests、Windows audit setup / worker tests成功。実監査はcanaryのflush / close後、filter setupの`scan-native-menu-state`段階で失敗し、native menu stateのcount-error分類lineは出なかった。`.PMC`保存 / WDIO / capture / control未到達、AC-05未達。失敗原因はrun evidenceから未確定。Run204後はPowerShellからC# `out` 引数を渡す境界を避け、countと固定failure enumを含むmanaged snapshotを返すよう変更し、`read-native-menu-count` stageを追加する。errorはP/Invoke直後に捕捉し、生error値を出さない。引き続き全失敗を拒否する。変更後のWindows runtimeは次runで検証する。

native [Run 206](https://github.com/65537i/mail-client-plan/actions/runs/40251553577)（`f521d65`、manual Windows 2025 x64 / webview）はplan、security-test build、WebView security tests、Windows audit setup / worker tests成功。実監査はcanary flush / close後の`read-native-menu-count`で失敗。sanitized診断は`failure-type:Other`でnative state lineは出ず、managed snapshot呼出し/取得の具体的失敗原因は未確認。`.PMC`保存 / WDIO / capture / control未到達、AC-05未達。Run206後はC# wrapperの戻り値をintに限定し、正常countか内部の負値statusを返す。Win32 errorはP/Invoke直後に捕捉してPowerShellで固定allowlist enumへ対応付ける。raw error / handleは出さず、全失敗は拒否する。新しいWindows runtimeは次runで確認する。

native [Run 208](https://github.com/65537i/mail-client-plan/actions/runs/40252567274)（`6ec4fcc`、manual Windows 2025 x64 / webview）はplan、security-test build、WebView security tests、Windows audit setup / worker tests成功。実監査は`read-native-menu-count`で失敗し、sanitized診断は`failure-type:Other`、native state lineなし。`.PMC`保存 / WDIO / capture / control未到達、AC-05未達。Run208後はnative method invocationと戻り値分類をstage分離し、PowerShell invocation wrapperのinner exception typeだけを限定allowlistで出す（message / stackは出力しない）。raw error / handleは出さず、fail-closedを維持する。次runで失敗位置とexception categoryを確認する。

native [Run 210](https://github.com/65537i/mail-client-plan/actions/runs/40253580555)（`b26e11a`、manual Windows 2025 x64 / webview）はplan、security-test build、WebView security tests、Windows audit setup / worker tests成功。実監査は`invoke-native-menu-count`で失敗し、allowlist診断は`EntryPointNotFoundException`、native state lineなし。原因はP/Invoke managed名を`GetMenuItemCountNative`に変更したときWin32 export名`GetMenuItemCount`を明記しなかったこと。`.PMC`保存 / WDIO / capture / control未到達、AC-05未達。修正は`DllImport(EntryPoint = "GetMenuItemCount")`を指定する。error capture・固定enum mapping・fail-closed guardは維持し、修正版Windows runtimeを次runで確認する。

native [Run 212](https://github.com/65537i/mail-client-plan/actions/runs/40254506604)（`654da74`、manual Windows 2025 x64 / webview）はplan、security-test build、WebView security tests、Windows audit setup / worker tests成功。`GetMenuItemCount` entry pointは動作し、native scanは`source:menu-owner`で`invalid-menu-handle`を得たため、owner `GetMenu`のnonzero値を有効なHMENUとは扱わず停止した。Invoke / `.PMC`保存 / WDIO / capture / control未到達、AC-05未達。Run212後は、popup / ownerともProcmon processと確認された場合に限り、popup HWNDの`GetMenu`をread-only候補として試す。候補のscanが全件成功し、対象項目が厳密に一意・checked offと確認できなければ引き続き拒否する。次runで候補の実Windows動作を検証する。

Run 214（`95e18e8`、Windows 2025 x64 / webview）はplan、security-test build、WebView security tests、Windows audit setup / worker tests成功後、`verify-drop-native-menu-state`で停止した。popup HWND自身からのWin32 `GetMenu`は利用可能handleを返さず、owner HWNDのmenu handleは`GetMenuItemCount`で`ERROR_INVALID_MENU_HANDLE`となった（diagnostic: `source:menu-owner;items:0;matches:0;read-failure:invalid-menu-handle;checked:unavailable`）。同一process境界は確認済みだが、UI stateは読めなかったためInvoke、`.PMC`保存、WDIO、capture、control判定へは進まず、AC-05未達。次のread-only候補として、同一Procmon processと確認済みのpopup HWNDにWin32 [`AccessibleObjectFromWindow`](https://learn.microsoft.com/en-us/windows/win32/api/oleacc/nf-oleacc-accessibleobjectfromwindow)を呼び、[`IAccessible`](https://learn.microsoft.com/en-us/dotnet/api/accessibility.iaccessible) child count / role / name / stateから`Drop Filtered Events`を厳密一致で読む。[`OBJID_CLIENT`](https://learn.microsoft.com/en-us/windows/win32/winauto/object-identifiers)を使い、最大64 child、exact unique match、`STATE_SYSTEM_CHECKED`のon/offを全て確認できた場合だけ結果を使う。COM読み取り失敗、想定外role/state、no/duplicate match、count超過、process不一致はいずれも不明状態として停止し、Invoke / `.PMC`保存へ進めない。Node diagnostics tests 15/15、JS syntax check、`git diff --check`は成功。診断parser testをWindows audit regression stepへ追加した。新MSAA経路のPowerShell / COM runtimeは未実行であり、Windows webview runで検証する。

Run 216（`9179aad`、manual Windows 2025 x64 / webview）はsecurity-test app buildとWindows audit setup / worker / filter-diagnostics regression tests成功後、実監査のfilter setup assertionで失敗した。canaryをflush / closeした直後にPowerShell childはnonzero exitし、harness出力には`PROC_MON_FILTER_FAILED_STAGE`やnative / MSAA state lineがなかった。PowerShell stderrは従来どおり破棄されるため、script parse、assembly load、helper compile、Procmon起動、または後段のどこで停止したかは特定できず、MSAAが実行された証拠もない。`.PMC`保存 / WDIO / capture / controls未到達、AC-05未達。次runに向け、UI Automation assembly load、MSAA assembly load、native helper compile、Procmon startを個別にtry/catchし、stageと固定例外型だけをstdoutへ報告する起動診断を追加した。失敗はnonzeroのまま保持する。Windows runtime未検証。

Run 218（`e017fe3`、manual Windows 2025 x64 / webview）はsecurity-test app buildとWindows audit / worker / diagnostics regression tests成功後、filter setupが`compile-native-menu-helper`で失敗した（`failure-type:Other`）。起動診断により停止stageは特定したが、compiler codeはまだ出力されず、IAccessible stateは未取得。`.PMC`保存 / WDIO / capture / controls未到達、AC-05未達。Run218後、`Add-Type`へAccessibility assemblyのpathを明示参照させ、compiler outputからC# error codeのみを限定診断する。ソース本文 / file path / 完全な例外メッセージは出さず、失敗は引き続きnonzeroとする。Node diagnostics regression testにcompiler-code allowlistを追加。明示referenceと新diagnosticのWindows runtimeは次runで確認する。

Run 220（`2e005c0`、manual Windows 2025 x64 / webview）はsecurity-test build / Windows regression tests成功後、MSAA state取得まで進んだ。Win32 handleは従来どおりinvalidだが、same-process `IAccessible`から11 children、対象1件、全読取成功、初期checked state `off`を確認した。filter setupは`verify-drop-native-menu-state`で失敗。harnessの8192文字first-only capに達し、invoke後state / failure markerがsummaryに残らなかったため、toggle後の成功・失敗は特定できない。fail-closedで`.PMC`保存 / WDIO / capture / control未到達、AC-05未達。Run220後は、同じ8192文字上限内で最初の3 KiBと末尾を保持し、中間を明示markするbounded head/tail captureへ変更し、後続stageと最終stateを残す。診断単体testでは上限・prefix・tail保持を検証する。

Run 222（`3cdd264`、manual Windows 2025 x64 / webview）はplan、security-test build、Windows audit setup / worker / diagnostics regression tests成功後、初期MSAA state `checked:off`を取得してInvokeした。しかしmenu popupはtoggle後に閉じ、同じ古いHWNDへの再readは`window-unavailable`となり、`report-msaa-menu-state`でfail-closedした。`.PMC`保存 / WDIO / capture / control未到達、AC-05未達。Invoke後にFilter menuを再openし、Procmon process一致・menu enabled / visible・exact unique targetを再検証してから新しいmenu HWNDをnative / MSAA state probeへ渡す修正を追加した。local Windows audit regression tests 21/21、JS syntax check、diff checkは成功。PowerShell runtimeと再open後のchecked state確認は次runで検証する。

Run 224（`1046f8a`、manual Windows 2025 x64 / webview）はplan、security-test build、Windows audit setup / worker / diagnostics regression tests成功後、Filter menuを再openし、MSAAで初期`checked:off`とInvoke後`checked:on`を確認した。toggle後stateを確認できた初回runだが、後続の`save-filter`でtimeoutし、Save Filter command未発見。`.PMC`保存 / WDIO / capture / controls未到達、AC-05未達。Run224後、Escape後にmain windowの`SetFocus()`を明示し、File menu openとSave Filter command検索へ別stageを置く診断を追加した。

Run 226（`ff0c13a`、manual Windows 2025 x64 / webview）はplan、security-test build、Windows audit setup / worker / diagnostics regression tests成功。Run224同様、MSAA stateはInvoke後`checked:on`になりtoggle確認を通過したが、`find-save-filter-command`でtimeoutした。`.PMC`保存 / WDIO / capture / controls未到達、AC-05未達。Alt+F SendKeysではFile menuが開かなかった可能性を考慮し、main window内の一意なFile MenuItemをUI Automation InvokePatternで開いてからSave Filter commandを検索する変更を追加。local tests 21/21、JS syntax、diff checkは成功。変更後のWindows runtimeは次runで確認する。

Run 228（`1a8dbef`、manual Windows 2025 x64 / webview）はplan、security-test build、Windows audit setup / worker / diagnostics regression tests成功。MSAAは初期`checked:off`からInvoke後`checked:on`となりtoggle確認を通過したが、`find-save-filter-command`でtimeoutした。`.PMC`保存 / WDIO / capture / controls未到達、AC-05未達。File MenuItemをmain descendantsから探す手法もruntimeで見つからなかったため、Alt+F後にFocusedElementからsame-process Menu ancestorを解決し、そのmenu descendantsからenabled / visible / exact unique `Save Filter...` itemを探すよう変更。local tests 21/21、JS syntax、diff check成功。変更後のWindows runtimeは次runで確認する。

Run 230（`9c54fef`、manual Windows 2025 x64 / webview）はplan、security-test build、Windows audit setup / worker / diagnostics regression tests成功。MSAAは初期`checked:off`からInvoke後`checked:on`となったが、`find-save-filter-command`でtimeout。`.PMC`保存 / WDIO / capture / controls未到達、AC-05未達。Run230後、Alt+F直後のfocused-control snapshotとbounded menu-item summaryを追加し、menu非表示とitem欠落を判別する。FocusedElementが最初の取得でnull / unavailableでも、既存5秒期限内にwait loopで再queryする。local regression testsとPowerShell runtimeは次runで確認する。

Run 232（`a47df87`、manual Windows 2025 x64 / webview）はplan、security-test build、Windows audit setup / worker / filter diagnostics regression tests成功。MSAAは初期`checked:off`からInvoke後`checked:on`となったが、`find-save-filter-command`でtimeoutし、`.PMC`保存 / WDIO / capture / controls未到達、AC-05未達。Alt+F後のFocusedElementはsame-process `MenuItem`で、親Menuも取得できていた。次の修正でfocused MenuItemの場合も親Menu内の子要素をbounded summary出力する。FileとSave Filter commandは固定safe labelのみにして、任意UI textはログへ出さない。

Run 234（`8720bc8`、manual Windows 2025 x64 / webview）はWindows関連regression tests成功後、初期MSAA `checked:off`とInvoke後`checked:on`を確認したが、`find-save-filter-command`でRuntimeExceptionとなった。初期Filter menuには`FilterCommand`と`SaveFilterCommand`が共存し、後続File menuの先頭8件には保存項目がなかった。従来の「timeout」という記述とは異なり、このrunはexact unique項目の欠落を明示して停止している。`.PMC`保存 / WDIO / capture / controls未到達、AC-05未達。File menuへ切り替える経路を除去し、既存Filter popup内の保存項目をInvokeする修正を加えた。任意UI textの非出力、8192文字上限、fail-closedおよび256 MiB gateは維持する。

Run 236（`97caac1`、manual Windows 2025 x64 / webview）はplanとWindows関連regression tests成功。MSAA `checked:on`、保存前Filter menu内の`SaveFilterCommand`を確認し、same-process / enabled / visible / exact unique / InvokePattern gateも通過した。その後`wait-save-filter-dialog`でRuntimeException。`.PMC`保存 / WDIO / capture / controls未到達で、AC-05未達。公式binary resourcesの調査でnamed filter保存とconfiguration exportを混同していたことを確認した。正しいFile → Export Configuration routeへ変更し、titleだけのdesktop検索を廃止。別process、main window自身、重複dialog、重複control、非表示・無効・read-only controlを成功扱いにしない。実際のexport dialogのUIA構造とcaptureへの到達は次runで検証する。

Rustのregistry / git依存と`target`をキャッシュし、OS・arch・runner・固定Rust版・lockfile / manifests / Cargo設定hashを区別する。同一モードを優先し、同じ依存条件の別モードからも復元可能。キャッシュhitでもbuild / testは省略しない。キャッシュは依存・ビルド出力のみで、資格情報ストア、監査trace、メールデータは含めない。初回はcold buildとなり、短縮量はrunnerで実測する。

同じevent・ref・対象・モードの古いrunだけをcancelし、pushによって進行中の手動調査をcancelしない。

fullのIMAP候補試験は`imap-poc,mime-poc`を併用し、BODY.PEEKで取得した合成literalからMIME解析までの統合試験も実行する。MIME単独の上限・診断試験は別stepで維持する。これは合成peerの試験であり、実IMAPサーバやliteralの読込中資源制限を保証しない。

同じIMAP targetで代替`imap-codec`の宣言長通知・入力分割時の制約・本文と最終statusの分離も評価する。codecはimap-poc限定のoptional依存で、本番default buildへは含めない。候補制約の再現test成功を採用gate合格と数えない。

既存framingの評価には別名optional依存の`imap-codec 2.0.0-alpha.7`も使用する。同じtargetで同時到着・分割入力・literal / 応答全体の上限を試験するが、test限定probeであり製品のTLS / session受信層を置き換えない。

同targetには1 KiB固定readとframingを結ぶ合成TLS受信試験も含む。上限・decode・EOF・期限・取消時の接続破棄と後続応答の保持を検証するが、製品のFETCH発行やUID / 最終tag照合との統合は別gateとする。

テスト限定の固定UID FETCH統合も同targetで実行し、上限付きTLS受信でUID / 完全BODY / 最終tagged OKと異常時の接続破棄を確認する。認証・mailbox選択・account scopeを実装した製品セッションの検証ではない。

同じbounded FETCHをSTARTTLS OK後のraw TCP→検証済みrustls streamへ引き継ぐ合成試験も実行する。STARTTLS拒否・未信頼証明書・hostname mismatchでFETCH / 認証へ進まず、plaintext fallbackをしないことを確認する。実サーバ・production connection managerの代替証跡にはしない。

さらにSTARTTLS昇格後のliteral上限超過、途中EOF、literal / 最終応答のdeadline・cancel時にprefix回収とTLS接続破棄を検証する。これは合成TLS peer上の試験で、実サーバやtask abort時の回収を保証しない。

IMAP候補targetには別途、STARTTLS昇格後にXOAUTH2 → EXAMINE INBOX → UIDVALIDITY / UIDNEXT取得 → 固定UIDのBODY.PEEK FETCHを同一のasync-imap sessionで行う合成試験を含める。FETCHはrun_command / read_responseで同一UID・完全BODY・一致tagged OKを明示確認し、NO / BAD / 別tag / 完了前EOFは失敗として接続を破棄する。これは小さい合成literalによるsession連携であり、bounded FETCH receiver、候補内部のliteral読込上限、account scope、UIDVALIDITY変更時の同期動作、実サーバへの接続は検証しない。

同targetでは、STARTTLS → 検証済みTLS → 合成XOAUTH2 → IDLE capability確認 → READ-ONLY EXAMINE → 合成EXISTS通知の受領 → DONE中に競合して届く別EXISTS burstのunsolicited channel配送とcapacity 100 overflow時の欠落 → IDLE再入 → manual cancellation / timeout / `* OK` keepaliveによるtimeout reset → overflow後のNOOP / `UID SEARCH ALL`と`UID FETCH 1:102 (UID FLAGS)`によるUID / flags再照合を行う。fixtureは検索後・FETCH前にUID 50が消失し、FLAGS応答が101件となる競合を作る。後続の完全UID検索でUID 50が存在しないことを確認し、tagged OK FETCHからの不在とUID集合からの消失を区別する。これは同期層のDB削除・transaction動作を実装するものではない。raw FETCH success / `NO` / partial-response後の`NO`も検査する。overflow時の自動再同期、UIDVALIDITY照合、DB永続化・差分更新は未実装。実サーバ、account scope、production connection managerや3OSでの追加test実行も証明せず、overflowは候補の未解決採用blockerのまま。

同じfixtureでは2回目の`UID FETCH 1:102 (UID FLAGS)`にtagged `NO`を返す異常系も確認する。async-imap 0.12.0の高水準`uid_fetch` streamはこれを空終端として返し、command失敗を呼び出し側へ示さない一方、後続NOOPは成功する。raw `run_command` / `read_response`では102 UIDのflags応答と一致tagged OKを確認し、別のtagged NOを拒否として識別した後に同一sessionのNOOPが成功することも確認する。さらに1件のpartial FLAGS FETCH後にtagged NOとなるfixtureで、取得件数が完全集合に満たないことと拒否statusを併せて検査する。従って呼び出し側でtagged completionと完全性を検証する候補経路はあるが、production adapterへの接続は未実装であり、高水準`uid_fetch`の空streamを正常な全件flags応答と解釈してはならない。

新epochのUID再照合では、高水準`uid_search("ALL")`に`* SEARCH 49 50`のpartial応答後tagged `NO`を返すと、候補APIは部分集合`{49, 50}`を正常な結果として返すことも確認する。共通raw UID SEARCH helperはpartial UID集合を保持しながら一致tagged `NO`と`BAD`をそれぞれ拒否として分類する。別caseではforeign-tag `OK`の後に一致tagged `BAD`を送り、callerが一致tagの完了まで読み進めても結果を`WrongTag`として不採用にする。正規の空`* SEARCH`+tagged `OK`とSEARCH応答がないtagged `OK`も区別し、後者は完全な空集合と扱わない。また、tagged `OK`後でも重複UIDおよびUID 0を含むSEARCH集合は不採用にする。完全UID集合検索へ高水準`uid_search`を単独利用せず、tagged statusと集合妥当性を明示確認する必要がある。これは候補欠陥再現で、production adapterの回避・チェックポイント保護は未実装。

UID SEARCH完了前EOF fixtureも実行する。`* SEARCH 49 50`後の接続断を高水準`uid_search`は部分集合の正常終了として隠すが、raw response readerは一致tagged completion前の`None`として検出する。完全集合検索はEOFで失敗扱いとし、結果・checkpointをcommitしない契約が必要。このtestはAPI差の再現でありproduction adapter / checkpoint transactionは未実装。

完全UID検索後の高水準`uid_fetch`にもpartial FETCH応答のみを返してtagged completion前にTLS closeする。APIはpartial `Fetch` itemをyieldし、その後通常stream終端を返してEOF error / missing statusを表さない。callerは全FETCH itemをprovisionalに保ち、一致tagged OKとUID集合の完全性を確認するまで同期成功・削除反映へ使わない必要がある。production adapterやDB境界への統合は未実装。

同じsessionの最後にINBOXを再EXAMINEしUIDVALIDITYを4242から4243へ変え、新しいUID集合（UID 50のみ）とそのepoch固有のFLAGSを取得する。前epochでUID 50が消えた後、同じ数値UIDが新epochで再登場する場合でもUID単独では識別できないことをfixtureで確認する。これはUIDVALIDITY変化の検出・再照会APIのPoCだけで、旧epoch参照やpending operationの無効化、DB epoch transaction、切断中のAC-08収束を実装・証明しない。

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
