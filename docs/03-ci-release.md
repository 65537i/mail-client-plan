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
  - `webview`: security-test用Tauri build（frontend typecheck / buildを含む）と実WebView / SecretStore試験。Linux `strace`、macOS `fs_usage`、Windows Process Monitorによるfile-access監査を実行する。Windowsはhosted runnerでcapture/exportまで確認したが、canary event検出と記録容量超過が未解決で、process coverageも未証明。production build、起動smoke、protocol、Rust workspace test / clippyは未実行。
  - `full`: 従来の全チェック。選択したOSだけのfullは全OSの証跡ではない。

全モードの前にLinuxの短いplan jobでCI選択ロジックとmacOS / Windows trace解析のNode回帰試験を行い、失敗したら重いmatrixを開始しない。選択scopeと部分検証の注意をActions summaryへ記録する。PRと節目の`all / full`で全OSのgateを確認し、basic / webviewの成功を総合検証成功と読み替えない。

Windows監査stepはProcmon captureをbaseline → attackの順に行う。baselineは専用WDIO configで既定UIを観測し、攻撃fixture / canary URLは渡さない。attackは従来の全security specsを維持する。各capture開始前にUI AutomationでcanaryとNode positive-controlの完全一致Path Include条件だけを持つ`.PMC`を生成し、Procmonを`/LoadConfig`で起動する。capture中は別の合成sentinelをNodeで読み、CSVにpositive-controlのNode `ReadFile`があり、sentinelおよび対象外pathがないことを必須とする。全process / operationの対象path eventを保持し、canary event、positive control欠落、想定外path、filter設定・読込失敗、256 MiB上限超過はいずれも失敗。Tauri / WebView2一般活動のProcmon観測は要求せず、WDIO実WebView試験の成功を独立の証拠とする。baselineは攻撃テストの代用でもSystem event除外でもない。raw traceは各capture終了時に削除する。run 87ではbaseline PMLが256 MiBを超え、export前に失敗したためattackは未実行。記録上限超過は監査不成立であり、イベント0件や攻撃遮断の証拠には数えない。UI Automationによるfilter生成・実Windows runtimeは初回実行前には未検証で、成功扱いにはしない。

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
