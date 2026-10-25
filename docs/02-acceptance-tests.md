# 受け入れ基準とテスト計画

## 1. 完了の定義

各Phaseは該当するACをすべて満たし、必須CIが成功し、手動試験の担当・OS・版・証拠が記録されて完了とする。skip、未実行、署名なしビルドを合格に読み替えない。重大な権限逸脱、秘密漏洩、データ喪失、自動重複送信につながる既知不具合は0件。脆弱性は到達可能性を評価し、重大/高の未解決問題は原則出荷を止める。例外は期限・緩和策・責任者を記録する。

実装時に各テスト名へAC IDを付与し、`docs/status.md`で要件 → AC → テスト → CI run / 手動証跡を対応付ける。

## 2. Phase別受け入れ基準

| ID | Phase / 要件 | Given / When / Thenの要旨 |
|---|---|---|
| AC-00 | 00 / NFR-03 | 空の開発環境からlockfile通りに3OSでbuildし、起動できる。依存選定ADR、OS対象、脅威モデル、禁止権限が確定する |
| AC-01 | 01 / NFR-01 | 不正IPC payload、別accountのfolder ID、未知commandを送っても、検証エラーになりデータへ到達しない |
| AC-02 | 01 / NFR-02 | DB初期化・migration・途中強制終了後に整合性を保つ。失敗時は元DBが残る |
| AC-03 | 02 / FR-01,02 | 独立した2アカウントを登録し、同じUID/Message-IDのメールを別々に表示する。切替時に他アカウントの本文が混ざらない |
| AC-04 | 02 / FR-02 | 日本語、multipart/alternative、添付、壊れた文字コードのfixtureを表示し、本文取得だけではサーバのSeenが変化しない |
| AC-05 | 02 / NFR-01 | HTML攻撃fixtureでscript/IPC/外部通信/ファイル読取/トップ画面遷移が全て0回。3OSの実WebViewで確認する |
| AC-06 | 02 / NFR-01 | 不正証明書・ホスト名不一致・STARTTLS拒否で認証情報送信が0回。秘密ストア不能時に平文ファイルが作られない |
| AC-07 | 03 / FR-03 | 同期中切断・再起動後、新着/削除/flagsが最終的にサーバと一致し、重複レコードがない |
| AC-08 | 03 / FR-03 | UIDVALIDITY変更後、古いUID参照が新メールへ適用されない。IDLEなし・拡張なしでもpolling/UID照合で収束する |
| AC-09 | 03 / FR-03 | ネット切断でキャッシュ済み本文だけ表示し、未取得はその旨を示す。アカウントAの失敗中もBは同期できる |
| AC-10 | 04 / FR-04 | オフラインの既読/スター変更を再接続後desired stateへ収束させる。クラッシュ再実行でtoggle反転しない |
| AC-11 | 04 / FR-04 | move/copy途中失敗・UID競合で誤削除しない。UIDPLUSなしで無関係なDeletedメールをexpungeしない |
| AC-12 | 05 / FR-05 | 新規/返信/全員返信/転送/添付をテストSMTP sinkで受信し、From・宛先・References・文字コードが正しい。Bccヘッダがない |
| AC-13 | 05 / NFR-02 | 送信ボタンを連打しても1ジョブ。DATA終端後切断とaccepted永続化前killでunknownとなり、自動再送が0回 |
| AC-14 | 05 / NFR-02 | SMTP accepted後にSent APPENDを失敗させてもSMTP送信は1回のみ。宛先一部拒否時は初版契約どおりDATAを送らない |
| AC-15 | 05 / FR-05 | 下書きの自動保存・再起動復元・送信revision固定が動作し、UI変更でqueued MIMEが変化しない |
| AC-16 | 06 / FR-06 | Google / Microsoftで初回同意・取消・期限切れ・更新・失効を試験し、秘密をUI/DB/logへ返さない |
| AC-17 | 06 / NFR-01 | state不一致・callback再利用・PKCE不一致を拒否する。同時IMAP/SMTP refreshがアカウント当たり1処理になる |
| AC-18 | 07 / FR-07 | 日本語3文字以上の部分一致・全半角正規化・複合条件・account scopeが期待結果と一致。1〜2文字の制限をUIに表示する |
| AC-19 | 07 / FR-07 | 本文更新/削除/再索引でFTSと原本が一致し、削除accountが検索結果へ残らない。未取得本文の対象外を示す |
| AC-20 | 07 / NFR-02 | 容量超過・disk full・DB破損・backup復元で下書き/outboxを勝手に消さず、復旧手順が実行できる |
| AC-21 | 08 / NFR-03 | 各対象OSへインストール・起動・アップグレード・アンインストールを実行し、署名/公証/更新署名を検証する |
| AC-22 | 08 / NFR-01 | 本番バイナリにWebDriver/debug port/テスト認証情報がなく、改変更新を拒否し、旧DBでの安全な起動制限が働く |
| AC-23 | 08 / FR-01〜07 | キーボードのみでアカウント切替、閲覧、検索、下書き、送信確認へ進める。各OSの読み上げ・日本語IMEを確認する |

AC-05のLinux CIでは、WebView/Tauriプロセスツリーのfile-related syscallsを`strace`で記録し、実行ごとに作る合成canaryファイルへのopen/stat/access試行がないことを直接確認する。この観測はLinux runner上の証跡であり、Windows/macOSや最低サポートOSの同等なOS-level auditを代替しない。

macOSでは`fs_usage`、WindowsではMicrosoft Sysinternals Process Monitorを使った合成canaryのOS-level auditを候補として評価する。runner上で観測権限、Tauri/WebView process coverage、canary path判定を実証できない場合は、そのOSのfile-access条件を未確認のままとする。実装・ログが未確認の候補をAC-05合格の証拠に数えない。

WindowsのProcmon captureは、UI Automationで保存・再読込する`.PMC`にcanaryとpositive-controlの完全一致Path Include条件だけを設定し、全process / operationの対象イベントを保持する。別の合成sentinelをcapture中にNodeで読み、positive-controlのNode `ReadFile`が記録され、sentinelが記録されないことをfilter動作の陽性・陰性controlとする。captureに他のpathが残る、control欠落、canary event、filter設定/読込失敗、256 MiB上限超過はいずれも監査失敗。Procmon上のTauri / WebView2一般活動観測は要件にせず、同じ実行でWDIO実WebView試験が成功したことを別証拠として記録する。これらはWindows上の全descendant coverageを証明しない。

macOS run 22で、system-wide traceにOS daemon `fseventsd`の`lstat64`が1件記録された。利用者確認済みのPoC判定として、この操作と`fseventsd.<数値>`の組み合わせだけを別集計してログへ明示する。それ以外のcanaryイベント（同daemonのopen/read、アプリ、WebKit、未知process / formatを含む）は失敗とする。これはシステム全体のcanaryイベント0件という旧判定からの限定的変更であり、完全なprocess coverageやAC-05合格の証明ではない。process名はtraceのprocess/thread欄に基づき、実行ファイルの同一性までは検証していない。

## 3. テスト層

| 層 | 道具候補 | 実行内容 / 位置付け |
|---|---|---|
| Rust unit/property | cargo test, proptest | UID集合、状態遷移、retry判定、アカウント境界、query compiler、パス検証 |
| UI component | Vitest, Vue Test Utils | 表示状態、pagination、エラー、送信account、unknown警告、a11y補助 |
| Repository | 一時SQLite / 実migration | 外部キー、unique、FTS同期、transaction rollback、WAL再開、migration失敗 |
| Protocol integration | TLS付きDovecot等 + SMTP sink + fault proxy | 本物のIMAP/SMTP、拡張ON/OFF、TLS、切断、遅延、受理後応答消失 |
| Deterministic protocol harness | Rust fake server / scripted server | UIDVALIDITY、EXPUNGE、部分応答、RCPT拒否、APPEND不明を再現 |
| Browser E2E | Playwright等 | UIロジックをIPC mockで検証。実Tauriの権限/WebView保証には使わない |
| Desktop E2E | Tauri対応WebdriverIO候補 | 実IPC、実WebView、保存ダイアログ周辺、HTML隔離、起動/再起動 |
| Native/実機 | OS資格情報ストア・署名済みapp | ロック/拒否、WebView差異、IME、証明書、通知、インストーラ |
| Fuzz / robustness | cargo-fuzz等 | MIME、ヘッダ、HTML sanitizer周辺、parser入力、FTS queryの異常入力 |

実サーバ試験とfake試験は両方必要。CIで本物の外部メールアカウントへ送信しない。SMTP sinkは外部relay禁止、テスト用証明書はCI内で生成して専用trustへ追加し、証明書検証無効化で通さない。

## 4. 固定fixture

- 2 accounts × 各3 folders、UID/Message-ID重複、同じ件名の別メール、INBOX case、非ASCIIフォルダ、特殊フォルダ不明。
- UTF-8、ISO-2022-JP、Shift_JIS、不正charset、RFC 2047ヘッダ、長いReferences、欠落Message-ID、RFC 2231添付名。
- multipart alternative/mixed/related、CID重複、巨大宣言サイズ、truncated MIME、30超のネスト、重複境界。
- script、event属性、SVG onload、CSS url/@import、form、meta refresh、iframe、javascript:/data:/file:、追跡pixel、Unicode偽装リンク。
- `../`、絶対パス、Windows予約名、UNC、二重拡張子、シンボリックリンク、NULを含む添付名。
- SMTPの送信前失敗 / DATA中切断 / final応答消失 / final受信直後kill / Sent保存失敗。

fixtureは合成データのみ。実メール・個人宛先・本物のtokenをコミットしない。悪意あるHTMLはデータとして保存し、テストコードの指示として扱わない。

## 5. 必須障害試験

| 注入点 | 期待結果 |
|---|---|
| UID batch DB保存直前/直後でkill | checkpointから再開し、欠損と重複がない |
| FETCH中EXPUNGE / UIDVALIDITY変化 | 古い参照を破棄し、誤本文・誤変更がない |
| Aのcredential lock / token失効 | Aは再認証待ち、Bは利用可能 |
| blob rename後・DB commit前kill | 起動後に孤立blob回収。参照済みblobは保持 |
| disk full / readonly / SQLITE_BUSY | データ保存成功を装わず、retry/空き容量案内 |
| pending moveのCOPY後kill | 再接続で結果照合。曖昧なら削除停止 |
| SMTP受理応答前後kill | 不明区間はunknown、自動再送なし |
| refresh token置換失敗 | token喪失を隠さず、安全に再認証可能 |
| account削除中のsync完了通知 | generationで破棄し、秘密やメールを復活させない |
| migration途中失敗 | rollbackまたはbackupから復元でき、前版の書き込みを防ぐ |

## 6. 性能とリソースの提案目標

基準機は4 core / RAM 8GiB / SSD、release build、固定fixture、ネットワーク条件を記録。Phase 00で測定し、目標変更はADRで理由を残す。数値は測定済み実績ではない。

| 指標 | 目標 / 測定方法 |
|---|---|
| 起動→キャッシュ一覧 | 10回のp95 3秒以内、ネット不要 |
| キャッシュ本文表示 | 100操作のp95 300ms以内、5MiB未満の通常メール |
| ローカル一覧ページ | 10万件メタデータでp95 200ms以内、50件keyset取得 |
| 全文検索 | 本文取得済み10万件、平均10KiB、3文字以上・scope付きquery 100種でp95 1秒以内 |
| 短い日本語query | scope制限・上限付き、2秒でキャンセル可能。無制限scan禁止 |
| UI応答 | 同期・索引中も入力・スクロールを継続可能。長時間UI停止を記録して改善 |
| メモリ | 通常閲覧・1 account同期時でRSS 500MiB目標。巨大MIMEを含むピークは別計測 |
| 安定性 | 3 accounts・8時間、切断/復帰/休止復帰を反復し、単調なメモリ増加なし |

## 7. 手動チェックと出荷証跡

macOS Keychain、Windows Credential Manager、Ubuntu Secret Serviceは実GUIセッションで保存/読出/拒否/lock/解除/削除を確認する。headlessの疑似成功で代用しない。OS休止復帰、プロキシ環境、DNS失敗、拡大率100/200%、IME入力、ダークモードを確認する。

Google/Microsoftの実プロバイダ試験は専用テストaccountで内部環境から実行する。送信先は管理下のsinkまたは許可された専用accountのみ。PR CIへrefresh tokenを配らない。

リリースごとにcommit SHA、依存lock hash、OS/WebView版、artifact hash、署名検証、公証結果、CI run、手動チェック、既知制約、backup復旧結果を保存する。未達ACはリリースノートだけで済ませず出荷判定で扱う。
