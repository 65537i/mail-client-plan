# ADR-002: IMAP候補ライブラリPoC

- 状態: 候補評価中。async-imap 0.12.0でTokio上のXOAUTH2・UID semantics・IDLE取消/polling fallback・rustls implicit TLS/STARTTLSとTLS拒否境界を合成serverで確認
- 決定日: 2026-10-20

## 背景

IMAP候補はTLS、SASL XOAUTH2、UID/UIDVALIDITY、IDLEの取消とpolling fallback、保守状況、3OS build、失敗時の扱いを調べてから採用する。実provider account、実サーバ、利用者メールは使わない。

## 候補と比較

| 候補 | 利点 | 残課題 | 現時点 |
|---|---|---|---|
| `async-imap` 0.12.0 | Tokio runtime feature、Authenticatorによる任意SASL challenge/response、UID command API、SELECTのUIDVALIDITY、IDLE handle、汎用AsyncRead/AsyncWrite transport | 既定featureはasync-stdなのでdefault-features=false必須。TLSは外部streamを接続する設計で、STARTTLS upgrade helperはない。upgrade前の認証禁止を呼び出し側で守る必要がある | 優先候補。未確定 |
| 同期`imap`系client | 同期コードの単純さ | Tauri/Tokio async runtimeとの統合でblocking回避・接続毎workerが必要。今回のPoCで比較試験していない | 未評価 |

## SMTP候補

| 候補 | 利点 | 残課題 | 現時点 |
|---|---|---|---|
| `lettre` 0.11.23 | Tokio async transport、SMTP final positive responseを`Response`として返し、negative responseは`Error::status`・transient/permanentで取得可能。rustlsの暗黙TLS / 必須STARTTLSを合成sinkで確認。MIT、Rust 1.85+ | DATA後の応答不明をunknownへ写像するのは呼び出し側責務。複数RCPTの個別結果は最初の拒否で中断される。production adapter / trust store方針は未実装 | 優先候補。未確定 |

## 実験

- `imap-poc` featureでは`async-imap` default featureを無効化し、`runtime-tokio`だけを有効化する。専用test feature以外のbuildにはIMAP crateを含めない。
- Tokio `DuplexStream`上の合成IMAP peerを使用し、server greeting → AUTHENTICATE XOAUTH2 challenge/response → SELECT → UID FETCHを実行。
- Authenticatorへ渡すcredential文字列は固定の合成tokenのみ。server側で受信したSASL payloadをbase64 decodeしてbyte-for-byte照合し、実資格情報・network接続は使わない。
- SELECT responseのUIDVALIDITY=4242 / UIDNEXT=9を確認し、UID FETCHの応答でUID=8とSeen flagを検証する。
- synthetic LOGIN後にCAPABILITYを確認し、IDLE対応peerではIDLE中断が`ManualInterrupt`となりDONE後に同じselected sessionでNOOP/LOGOUTできること、IDLE非対応peerではNOOP pollingへ進むことを確認する。
- 合成証明書を`localhost`用に生成し、rustlsの通常のroot/hostname検証を維持してimplicit TLS streamを`Client`へ渡す経路と、STARTTLS OK応答後にraw streamを取り出してTLS upgradeしたうえで`Client`を作り直す経路を確認する。両経路でTLS成立後のみにXOAUTH2を送信する。統合fixtureで不可信証明書・hostname不一致・STARTTLS拒否時に認証データが0 bytesであることも確認する。
- commandとqueryは固定fixture。ユーザー入力をrun_command / MATCH文字列等へ直接通す用途を認めない。mailbox名・search条件は型付きvalidatorとparameterizationをadapterに置く。
- `smtp-poc` featureでは`lettre` default featuresを無効化し、`smtp-transport` / `tokio1-rustls-tls`を有効化する（Tokio / rustls / ring / webpki-rootsを含む）。rcgen / rustls / tokio-rustlsも同PoCだけで有効にする。loopback scripted sinkでDATA final 250 response、DATA後final 550 responseのstatus取得、RCPT拒否時にDATAへ進まずQUITすることを試験する。これらのtransaction testsは固定ASCII合成データで、外部relay・credentialsを使わない。
- AC-13に向けた候補評価として、sinkがDATA終端まで受信した直後に接続を閉じる場合と、`250 2.0.0 queued`をCRLFなしで途中送信して閉じる場合を追加。両方でsend_rawが成功でもSMTP拒否statusでもないエラーを返し、sinkの本文とDATA回数1件を検査する。listenerを閉じず250ms監視し、この観測窓で自動再接続がないことも確認する。これは候補の単一send呼び出しの評価であり、永続Outboxのunknown分類・再起動復旧・長期間のretry禁止は証明しない。
- SMTP TLS fixtureではrcgenのlocalhost証明書をtest専用rootとして明示的に信頼し、通常の証明書・hostname検証を維持する。`Tls::Wrapper`または`Tls::Required`を明示し、opportunistic / plaintext fallbackは使わない。`test_connection`でTLS後のEHLO → 合成AUTH PLAIN → NOOP → QUITを確認する。STARTTLS前にもAUTHをadvertiseするがclientはTLS確立まで認証しない。信頼しない証明書・信頼済みだがhostname不一致を両TLS方式で試し、rustlsのtyped InvalidCertificateをerror source chainから確認する。STARTTLS 454拒否・capabilityなしも別ケースで確認する。平文で観測してよいcommandはEHLO / STARTTLS / QUITだけに限定し、認証・本文データの漏出を拒否する。
- 同じTLS fixtureを`send_raw`にも使用し、両方式でAUTH後のMAIL / RCPT / DATAと合成本文を検証する。最終250、最終550、DATA終端受信直後のTLS切断を各方式で試し、本文のwire bytes（lettreが終端前に追加するCRLFを含む）とAUTH / MAIL / RCPT / DATAが各1回であることを検査する。lost reply時はlistenerを250ms維持して再接続なしを確認する。TLS認証テストと本文テストは同じtransport構築・平文command制限を共有する。

## 結果

| 確認 | 結果 |
|---|---|
| Tokio integration | `cargo test -p mail-client --features imap-poc --test imap_candidate --locked` 成功 |
| XOAUTH2 challenge/response | 合成payloadのchallenge flowを確認 |
| UID semantics | SELECT UIDVALIDITYとUID FETCH responseを確認。実装側は必ず(account, folder, UIDVALIDITY, UID)でpersistし、sequence number単独参照を禁止 |
| BODY.PEEK → MIME（AC-04前提） | imap-poc + mime-poc併用の新規2 tests。EXAMINE / UIDVALIDITY、UID FETCHのBODY.PEEK[]完全一致、1 / 17 / 全byte分割literalの全原文復元、MIME本文・診断、取得後のUID FLAGS / LOGOUT成功。literal途中切断はerrorで成功FETCHなし。Linux arm64でunit5 + IMAP10 + MIME42 = 57 tests、対象clippy / format / diff成功 |
| IDLE cancellation | wait timeout stopで`ManualInterrupt`を確認。DONE送信後に同じselected sessionでNOOPとLOGOUTが成功 |
| Fallback | IDLEをadvertiseしないpeerでIDLEを呼び出さずNOOP pollingとLOGOUTが成功 |
| TLS | rustlsの証明書・hostname検証を使い、implicit TLSおよびSTARTTLS後のasync-imap stream再構成を確認。不可信証明書・hostname mismatch・STARTTLS拒否の全ケースでIMAP統合fixture上の認証データ0 bytesを確認 |
| SMTP final response | lettreがpositive final 250を`Response`で返し、DATA後の550拒否をpermanent error/status 550として保持することをloopback sinkで確認 |
| SMTP RCPT拒否 | RCPT 550に対しDATAを送らずQUITすることをloopback sinkで確認。複数宛先の部分受理表示は未実装 |
| SMTP lost / truncated final response | Linux arm64で2ケース成功。sinkは本文とDATA終端を受信済みだが、clientに最終受理応答はなく、statusなし・transient/permanentのいずれでもないエラーとなる。単一send呼び出し中と切断後250msの観測で再接続なし。CRLF未完の250も成功扱いにしない。SMTP候補testは計5件成功、対象clippy成功 |
| SMTP TLS / 認証境界（AC-06） | Linux arm64で8ケース成功（暗黙TLS / 必須STARTTLSの成功2、証明書不可信2、hostname不一致2、STARTTLS拒否 / 未advertise各1）。成功時のみ暗号化後AUTH 1回、否定経路は認証0回。既存5件を含めSMTP 13 tests、対象clippy成功。IMAP 8 + 汎用TLS 3とのfeature併用でも計24 tests成功 |
| SMTP TLS本文送信（AC-12 / 13の前提） | Linux arm64で6ケース成功（暗黙TLS / 必須STARTTLSそれぞれ250受理、550拒否、最終応答消失）。合成本文は各1件、認証・envelope・DATAは暗号化後各1回。lost replyではstatusなしのエラーで成功扱いにせず、250ms内の再接続なし。既存分を含めSMTP 19 testsと対象clippy成功。永続OutboxやSent保存の試験ではない |
| 3OS build / CI | workflow matrixに同じin-memory testを追加。GitHub Actions未実行 |

## 未達・採用gate

### 要求UIDと完全BODY応答の整合性PoC

- test限定checked_fetchのUID判定を「UID 8がどこかにある」から「UID属性がちょうど1個で8」に変更。BodySectionのindexは部分取得originを表すためSome(0)も完全BODY[]とは扱わず拒否する。固定imap-proto 0.17.0の公開BodySection型（index: Option<u32>）とparser対応を配布sourceで確認した。本文重複の既存拒否も回帰試験へ追加した。
- 新規2 testsで別UID / UID欠落 / UID重複 / 同応答内の本文重複 / origin 0 / origin 17を注入。修正前にUID重複と部分本文を完全な未確定本文へ格納する失敗を再現。修正後はUnexpectedResponseで返りsessionを破棄し、peerで後続commandなし・EOFを確認。UID不正と部分本文はprovisionalへ入れず、本文重複は最初の未確定本文を保持し後のbytesで上書きしない。初回のtest scope警告・型field名compileエラーは修正した。
- Linux arm64でunit5 + IMAP18 + MIME42 = 65 tests、対象clippy / format / diff成功。うち既存2件は高レベルAPIの欠陥再現であり採用合格ではない。これは未要求応答をfail-closedに拒否する限定PoCで、正当なunsolicited FETCHの処理やaccount / folder / UIDVALIDITY所属を保証しない。literal allocation上限・途中prefix回収・実サーバ・3OSは未達。製品コード・依存・workflow変更なし、本番採用blockerは維持。

### 未確定の完全literalの保持・回収PoC

- test限定owned_checked_fetchがOption<Vec<u8>>を所有し、checked_fetchは借用した保持領域へ完全literalを格納するよう変更。selectで待機futureが取消されても保持領域は残り、FetchFailureへcauseと未確定本文を格納して返す。into_partsで明示回収でき、manual Debugはcauseと保持byte数のみ。sessionは全失敗でdropし、成功は一致tagのOK後のみ(session, body)を返す従来契約を維持する。
- 既存の異常系testsを強化し、NO / BAD / 完了なしEOF / 別tagおよび完了待機中のtimeout / cancellationでSOURCEの全bytes回収を確認。本文なし / 途中literal / 事前中断はNoneで、未取得を空本文成功に置き換えない。診断にSubjectやSynthetic本文がないこと、peer側接続終了・後続commandなしのassertも維持。Linux arm64でunit5 + IMAP16 + MIME42 = 63 tests、対象clippy / format / diff成功。件数は既存を強化したため増加なし。欠陥再現2件は採用合格ではない。
- 取得済みliteralでもFETCH全体の成功未確認なので、未確定状態で扱い完全cacheへ昇格させない。candidate内部の途中literalは依然回収できず、永続化・future自体drop / abort時の回収・読込allocation制限・TCP / TLS終了・unsolicited配送・account scope・3OSは未検証。製品コード・依存・workflow変更なし、本番採用blockerは維持。この後続PoCで以前の「完全literalも中断で失われる」制約のみ解消し、途中literalの制約は残る。

### FETCHの期限・取消とsession消費の限定PoC

- test限定owned_checked_fetchはDuplexStreamのsessionを所有し、既存checked_fetchを絶対deadline / cancellation Futureとselectする。ready取消を期限より優先し、既に期限を過ぎていればcommandをpollしない。一致tagのOKによる成功時だけ(session, body)を返し、その他のerror経路はsessionをdropする。中断したprotocol状態をそのままcallerへ返さない所有権契約を評価したもので、本番adapterではない。
- 新規2 testsで途中literal / 全literal受信後の完了待機を各timeout・取消で止め、peer側read_to_endがEOFとなり再試行 / NOOP / LOGOUTが送られないことをassert。事前に取消・期限切れのケースはFETCH自体0 bytes。既存checked APIの正常系もwrapper経由で後続command成功を確認し、NO / BAD / EOF / 別tag / 本文なし / literal途中切断でもpeerが接続終了を観測するようfixtureを補強した。初回のenum配置とtest scopeのcompile問題を修正後、Linux arm64でunit5 + IMAP16 + MIME42 = 63 tests、対象clippy / format / diff成功。既存高レベルAPIの欠陥再現2件は採用gate合格ではない。
- 制限: cancellation / deadlineでchecked_fetch内の一時本文やcandidate内のpartial literalは失われる。prefix回収・未完原文の永続保存を提供する本番契約ではなく、このPoCをデータ保持実装として使わない。TCP / TLSの終了、task abort / future自体のdrop、literal allocation上限・CPU制限・unsolicited配送・account scope・3OSは未検証。新依存・workflow変更なし。本番採用blockerは維持する。

### 完了確認可能な公開低レベルAPIの限定PoC

- 配布sourceで公開run_command / read_responseとimap_proto再公開を確認し、test限定のchecked_fetchを追加した。固定UID 8を要求し、parsed Response::FetchのUID / BODY[]を一時保持し、run_commandが返したtagと一致するResponse::DoneのStatus::Ok後だけbytesを返す。NO / BADはRejected、tag前EOFはMissingCompletion、別tagはUnexpectedResponse、途中literal切断はIo、OKだが本文なしはMissingBody。元response / error文字列はtyped errorへ格納せず、本文をerrorへ含めない。未対応応答や重複本文はfail-closedに拒否する。
- 新規2 testsで正常3種類のfragment、異常6 scenarioを検証し、正常時にはMIME解析と後続flags command / LOGOUTも確認。Linux arm64でunit5 + IMAP14 + MIME42 = 61 tests、対象clippy / format / diff成功。既存高レベルAPIの欠陥再現2件は維持し、成功を採用合格と読み替えない。新依存・workflow変更なし。
- これはwire parserを新規作成せず候補のparsed responseを使うAPI評価に限る。本番adapterではなく、固定UID・DuplexStreamのみ。unsolicited応答の正規配送、account / folder / UIDVALIDITY scope、期限と取消を含むsessionの消費的所有権、literal読込前のallocation上限、失敗時prefix保持は未実装。高レベルuid_fetchは引き続き本番採用不可で、低レベル経路もこれらのgate解消まで本番へ接続しない。実サーバ・3OS runtimeは未検証。

### FETCH完了statusを失う採用blocker

- async-imap 0.12.0のuid_fetchで完全literalを受信した後、(1)一致tagのNO、(2)一致tagのBAD、(3)tag付き完了応答なしのEOFを注入した。全ケースでSome(Ok(Fetch))の次がNoneとなりerrorを受け取れない。最初の「必ずerrorが出る」期待の2 testsは失敗した。MIME解析可能な本文やstream終端だけでコマンド成功と判断してはならない。
- 配布sourceのparse.rsでparse_fetchesがtake_while(filter)を使い、filter_syncはResponse::Done { tag, .. }のtagだけを見て除外することを確認。NO / BADのstatusがcallerへ届かない。imap_stream.rsではbufferが空のEOFをNoneとするため、complete FETCHの後に完了tagが来ないケースも成功終端と区別できない。literal途中EOFの既存error試験は引き続き成功する。
- 評価testsはcandidate_limitationの名前で現状の欠陥をassertする。これは採用gateを緩和せず、検出した非対応機能を記録するPoCである。固定版のこのAPI経路は本番採用不可。上流修正 / 別API / 別候補でtag付きOKと欠落時errorを明示取得できるまで採用しない。NO後にNOOP成功を確認しても元FETCHの成功証明にならず、代替策にしない。変更はtest fixtureと文書のみ、registry sourceや依存版は変更していない。
- Linux arm64で新規2 tests（NO / BAD / EOFの3 scenario）を含むunit5 + IMAP12 + MIME42 = 59 tests、対象clippy / format / diff成功。ただし2件は欠陥を再現した成功でありAC-04や候補採用の合格ではない。3OS runtime・実サーバ・永続化は未検証。既存のliteral読込中size / cancellation / prefix保持の未達も維持する。

### IMAP本文取得とMIMEの接続PoC

- `tests/protocol/imap_body.rs`をmime-poc有効時だけIMAP test targetへ追加し、native fullのIMAP stepを`--features imap-poc,mime-poc`へ変更。単独imap-pocの既存試験は維持。公開login APIで合成認証後にEXAMINEし、UID 8のBODY.PEEK[] literalをMIME adapterへ渡す。本文中に`)`やtag付き応答に似た行があっても原文を誤分割しないことを確認。切断fixtureでは部分literalを成功として返さず、sessionを破棄する。全体timeoutは各scenario 3秒。
- fixtureのFLAGS ()は固定合成応答で、BODY.PEEK[]のwire選択とclientのflags解釈を確認したにとどまる。EXAMINEのread-only保護もあり、実IMAPサーバのSeen semanticsの証明ではない。認証はメモリ内DuplexStreamと合成値のみで、平文ネットワーク認証を製品へ許可する変更ではない。
- async-imap自身がliteralをbufferしてからFetch::body()を返す。このPoCで指定長readerを内部へ差し込んでいないため、既存readerの読込前50MiB gateや部分原文回収がそのまま適用されるとは扱わない。実ネットワークに接続する前にliteral読込中のsize / timeout / cancellation / prefix保持とaccount-scoped参照を接続する必要がある。実サーバ、永続化、UI、3OS、解析中資源制限は未確認。actionlintは環境になく今回は未実行、workflowは既存stepのfeature指定だけを変更した。

### MIME候補の初期PoC

- 候補: `mail-parser` 0.11.9、Apache-2.0 OR MIT。crates.ioの公開metadataと配布crateのAPI / featureを確認し、`mime-poc`専用のoptional依存として固定。default featuresなし、`full_encoding`だけを追加してShift_JIS / ISO-2022-JPを扱う。frontend / 本番default buildへは接続しない。
- 合成fixtureの6 testsをLinux arm64で実行し、UTF-8 / Shift_JIS / ISO-2022-JP本文とRFC 2047件名、multipart/alternative、RFC 2231添付名とbase64 bytes、重複CID、不正base64、閉じ境界のないmultipartを検証した。対象clippy / format / actionlint成功。native fullに同じtest targetを追加し、Windows/macOSは未実行。
- パーサはsanitizerではない。HTMLのscriptはそのまま返り、RFC 2231添付名の`../`も保持され、同一CIDの異なる添付2個も残る。HTMLは未信頼のままRust sanitizerとsandboxへ渡し、添付名を保存pathに使わず、CID重複は明示的な曖昧状態として処理するadapterが必要。
- 不正base64は`is_encoding_problem`で検出できた。閉じ境界のない合成multipartではparseがSomeを返しraw sourceを保持する一方、body_text / body_htmlはNoneとなった。初回の「本文を復元できる」という期待は失敗し、候補の実測制約として試験に固定した。Someだけで完全な解析成功にしない。原文を保持し、本文なし / 解析不完全を明示する製品側契約が必要。
- 追加の5 testsで、不正UTF-8はU+FFFDへ置換され、未知charsetのASCII本文は読めても、いずれも`is_encoding_problem`がfalseとなることを確認。このflagはcharset復元の正確性や完全性の保証には使えない。原文を保持し、charsetの認識可否・置換・転送復号不良を別の診断として扱うadapterが必要。
- multipartネスト29 / 30 / 31 / 128で、全partの親子関係・深さ・末端本文が保持された。添付binary 25MiBの-1 / 境界 / +1 byte、原文text/plain 50MiBの-1 / 境界 / +1 byteでも全bytesが解析された。パーサに製品のネスト30 / 添付25MiB / 原文50MiB拒否を任せることはできない。入力raw byte上限は解析前、復号後・添付・構造の上限は原文を失わない明示エラー経路で適用する必要がある。解析後だけの検査では解析中の資源消費を抑止できない点も未解決。
- Linux arm64で既存6 + 追加5 = 11 tests成功（test本体約2.11秒）、対象clippy `-D warnings` / format / diff検査成功。これは合成fixtureの完走確認であり、解析時間の性能gate・メモリ上限・DoS耐性の証明ではない。大きいfixtureは実行時生成し、ファイルやartifactに保存しない。
- 未達: RFC 2231 continuation、multipart/related、message/rfc822、重複境界、不正な多バイトcharsetの詳細、復号後合計100MiB境界、fuzz、解析時間・メモリ計測。設計の各上限を適用する本番adapterは未実装。今回のfixture群は耐性全体・採用確定・AC-04完了の証明ではない。

### MIME制限adapterのPoC

- 指定長入力の`read_source_literal_async`を追加。宣言長はu64のまま50MiB上限と比較し、超過は0 bytes消費・空prefix付きTooLargeで拒否する。このpreflightは取消 / deadlineより優先。許可された宣言長はTokio AsyncReadExt::takeで区切り、既存read_source_asyncで読む。長さ到達を論理EOFとして扱うのでstream全体の切断を待たず、後続のprotocol bytesを消費しない。実EOFが早ければUnexpectedEofのio::Errorとprefixを返す。deadline / cancel / I/O失敗時も既存の安全なerrorと原文回収経路を使う。新規5 testsで0 / small / 50MiB -1 / 境界、合成FETCH suffix保持、short EOF、上限超過とu64::MAX、pending readのtimeout / cancellation、ready取消優先を確認。Linux arm64でunit5 + integration42 = 47 tests、対象clippy / format / diff成功。新依存・workflow変更なし。これは宣言長を渡す低レベルPoCでIMAP応答parserやasync-imapとの接続ではない。不正な長さを自力検出せず、短く宣言されたsourceはその長さで成功する。エラー時にdrain / reconnect / 自動再試行せず、protocol境界の回復または接続破棄はcaller責務。中断後のsession再利用やfuture drop時のprefix回収、解析中の資源制限、3OS runtimeは未検証。
- RFC 2231 continuationを検証。文字単位で分割された日本語filenameとsegmentの逆順配置は正しく復元された。一方、UTF-8の「日」を%E6%97と%A5へsegment分割すると、mail-parser 0.11.9は「U+FFFD U+FFFD 本語.bin」を返す。初回の完全復元assert失敗を制約として記録し、出力の完全一致・転送復号flagはfalse・添付bytes正常・原文保持を回帰試験へ固定。`attachment_name_replacement_character_present`を診断へ追加し、既存反復走査でnested message内の添付名も確認する。診断に生filenameは含めない。元からU+FFFDを正しく含む名前もtrueになるため変換損失の確定判定ではない。分割された../、Windows相対パス、絶対パスもparserがそのまま返すことをassertし、保存pathとして信頼しない契約を維持。Linux arm64で新規4 testsを含むunit5 + integration37 = 42 tests、対象clippy / format / diff成功。名前の完全復元や安全な保存API、UI通知は未実装で、既存parseの結果を変更していない。新依存・workflow変更なし。全RFC 2231異常系・解析途中資源制限・3OS runtimeは未検証。
- 重複Content-IDの診断を追加。既存反復走査で各Messageのrootを訪問するとき、そのMessageのpartsだけをHashSetで検査する。空でないparser出力CIDの完全一致で`duplicate_content_id`を設定し、生CIDを保持 / Debug表示しない。大小文字の違いは一致とせず、異なる添付messageの名前空間を混ぜない。nested message内の重複は同じ診断boolへ集約する。各Messageを1回だけ検査し、添付 / 本文 / 原文の受理契約を変えない。新規3 testsで同一 / 一意 / 大小文字違い / CIDなし / 外側と2つの添付messageで同一CID / nested重複 / 診断非公開を確認。Linux arm64でunit5 + integration33 = 38 tests、対象clippy / format / diff成功。これはmessage単位の保守的な曖昧性診断であり、multipart/relatedやalternativeごとのCID選択、CID URLのpercent復号・正規化、重複ヘッダの全検出、画像内容検証、表示許可の実装ではない。既存charset診断にboolを1つ追加しただけでUI / IPC未接続、新依存・workflow変更なし。AC-05実WebView試験の代替にはせず、解析中資源制限・3OS検証は未達。
- 本文文字コード診断を追加。`parse_with_diagnostics`は既存上限 / 不完全検査を通ったMessageと`MimeDiagnostics`を返す。`unrecognized_text_charset`はText / Htmlに宣言されたcharsetが固定版decoder mapで認識されず、UTF-8 / utf8でもない場合。charset未指定は未知と断定しない。`replacement_character_present`はdecoded文字列にU+FFFDが存在することだけを表し、原文に正しくエンコードされたU+FFFDがあってもtrueとなるため変換損失とは呼ばない。既存の反復tree走査を再利用してnested message / text添付も扱い、binary / headerには適用しない。診断は2つのboolのみで未信頼charsetや本文をDebugへ出さない。`parse`は同じ経路からMessageだけ返し、既存の受理 / エラー / 本文契約を保つ。新規4 testsを含めLinux arm64でunit5 + integration30 = 35 tests、対象clippy / format / diff成功。固定版の公開`charset_decoder`とparserのUTF-8 fallback経路を配布sourceで確認。UI / IPC未接続。変換がlosslessである保証・全charset alias認識・header診断・全不正MIME検出・解析中資源制限・3OS検証は未完了。新依存・workflow変更なし。
- base64の実復号を通る添付25MiB境界を検証。multipart/mixedのattachmentとmultipart/relatedのinline画像指定を各25MiB -1 / 境界 / +1 byteで生成し、76文字の折返しと全3種のpadding長を含めた。原文は全ケース50MiB未満。候補parserはbinary / inline binaryの全decoded bytesを期待どおり返し、encoding problem flagはfalse。adapterはどちらの指定も境界以下を許可、+1 byteはAttachmentTooLargeとする。受理結果の全decoded bytesとraw source一致もassertした。Linux arm64でunit5 + integration26 = 31 tests、対象clippy / format / diff成功。製品コード・依存・workflow変更なし。image/png宣言のpayloadは合成ASCIIであり、画像のmagic bytes / decoder安全性、CID解決、HTML安全化は検証していない。添付messageのbase64再帰、解析途中のCPU / memory制限、3OS runtimeは未検証。
- 転送エンコードされたmessage/rfc822の候補内部制限を検証。固定版実装のMAX_NESTED_ENCODED = 3を確認し、quoted-printableの1 / 2 / 3 / 4 / 5段fixtureで実測した。3段までは末端本文が一致しadapterも許可。4 / 5段では3段のみ展開され、次の復号済みmessage bytesをBinaryとして保持しis_encoding_problem = trueとなる。adapterは既存のtree全体のflag検査でIncompleteを返す。元EMLとBinaryに残る各層のbytesを完全一致で検証し、診断に合成本文が出ないこともassert。製品のネスト30を満たすことと、全添付messageを解析できることは同義でない。初回fixture配置と未解析bytesの期待値を修正後、Linux arm64でunit5 + integration25 = 30 tests、対象clippy / format / diff成功。製品コード・依存・workflow変更なし。base64 / encoding混在、全不正MIME診断、解析途中の資源制限、3OSは未検証。このquoted-printableケースでは「内部制限で未解析の添付messageが成功扱いになるか」の懸念は再現せず、明示エラーを確認した。
- 実EMLの復号後100MiB検証を追加。Windows-1252の0x80（UTF-8では3 byteのeuro sign）とASCIIの端数を組み合わせ、原文50MiB未満からdecoded 100MiB -1 / 境界 / +1 byteを生成する。候補parserは全ケースを解析し、全decoded bytesが期待どおりでencoding problem flagはfalse。adapterは境界以下を許可し+1 byteでDecodedTooLargeを返し、callerの原文を維持する。Linux arm64でunit5 + integration24 = 29 tests成功、固定長chunksのclippy指摘修正後に新規test再実行・対象clippy / format / diff成功。先行PoCの「実入力からの100MiB超過未検証」はこのcharset展開ケースに限り解消。複数part合算は既存unitで検証しており、今回の実入力は単一text part。解析は上限検査前に完了するため、CPU / peak memoryの計測・制限、fuzz、3OS検証の代替にはしない。製品コード・依存・workflow変更なし。
- 非同期readerのInterrupted再試行でyieldを迂回する不具合を修正。単一threadのTokio executorで、prefix受信後のInterruptedから予約された取消taskが実行され、Cancelledとprefixが返る回帰試験を追加した。修正前は64回の有限再試行後にI/Oエラーとなる失敗を確認し、修正後は64回未満で取消成功。Interruptedも既存の共通yieldへ進めるだけで、同期readerや他のI/Oエラー処理は変えない。Linux arm64でunit5 + integration23 = 28 tests、対象clippy / format / diff成功。実IMAP・3OS runtime・解析中の資源制限の未達は維持。
- 非同期版`read_source_async`を追加し、既存固定Tokioを`mime-poc`で有効化。借用したAsyncReadと絶対deadline、完了時に中断するFutureを受ける。deadlineはchunkごとに延長しない。ready cancellation → 期限 → readの優先順で、各loopの期限判定を明示し、即時read可能な入力でも期限超過後は読まない。loop間でyieldし連続ready入力でも他taskを進める。同期readerの中断をthread放置で模倣せず、Tokioのcancel-safeなreadを使用する。
- TimedOut / Cancelledを型付きcauseへ追加し、I/O失敗・上限超過と同じくprefixを回収できる。readerはborrowしたままで、自動close / 再試行 / 未読stream消費をしない。呼び出し側はdropによるfuture取消ではなく、渡したcancellation Futureを完了させて回収経路をawaitする必要がある。関数futureやtask自体をdrop / abortした場合のprefix回収は保証しない。
- 非同期6 tests追加。empty / small、50MiB -1 / 境界 / +1 / +100、ready取消と期限切れで0 bytes消費、途中取消、pending read中の取消・期限切れ、Interrupted後のI/O失敗、診断のprivate data非公開、未読streamの継続利用を確認。初回は期限切れタイマーの準備よりready readが先行する失敗を検出し、毎loopの期限比較を追加して修正。同期readとasync extensionの名前衝突も明示Read呼び出しで修正。最終的にLinux arm64でunit5 + integration22 = 27 tests、対象clippy / format / diff成功。
- 非同期化は読み取り待機の制御だけで、同期MIME解析中のdeadline / cancellation / メモリ制限を提供しない。IMAP literalのframingや中断後のprotocol session再利用は未接続・未検証。raw streamをそのまま再利用できることをIMAP sessionの安全な継続と読み替えない。UI / IPC / 永続保存には未接続。

- 入力stream向けにblocking `read_source(&mut impl Read)`を追加。16KiB単位で読み、原文50MiB + 1 byteまでで必ず判定する。50MiBちょうどはEOF確認後に成功、1 byte超過はエラーで停止し、残りのstreamを消費しない。上限超過で返すbytesは完全なメールではなくprefixであることをエラー表示に明記する。読み取り成功後のVecを既存`parse(&raw)`へ渡すPoCを試験した。
- 読み取りエラー時は取得済みbytesと元のio::Errorを`into_parts()`で回収できる。Interruptedだけ再試行し、その他のI/O失敗をEOFや空の成功にしない。Display / Debugは本文・I/Oエラー文字列を伏せ、分類と保持bytes数のみを出す。Error::source経由の不用意なpath公開も避け、元のエラーは回収APIからのみ取得する。
- 追加4 tests（unit計5 + integration16 = 21）でempty / small、short read、Interrupted後のI/O失敗、原文50MiBの-1 / 境界 / +1 / +100 byteを確認。超過後にstreamの残りが維持されること、部分原文と元エラーの回収、診断非公開もassert。Linux arm64で全21 testsと対象clippy / format / diff検査成功。依存・workflow変更なし。
- 入力stream上限はこのblocking readerを使う場合のみ有効。UI threadでは呼ばない。deadline / cancellationは呼び出し側の責務で、遅いstreamのread停止、IMAPへの組み込み、prefixと未読streamの永続保存は未実装。parser自身の途中資源消費や不完全MIME診断の網羅性は今回改善していない。

- `src-tauri/src/mime_poc.rs`を`mime-poc` featureだけで公開。借用した原文sliceを受け、50MiB超過をパーサ呼び出し前に`RawTooLarge`として拒否する。呼び出し元が原文を所有し続け、エラーに本文・添付名・pathを含めない。UI / IPC / DB / filesystemには接続しない。
- 解析後のpart treeを反復走査し、添付25MiB、復号後合計100MiB、container深さ30を超過した場合に型付きエラーを返す。root containerから数え、multipartとmessage/rfc822を各1段とする。nested messageは元のmessage bytesと内部decoded leavesを両方合算する保守的budgetとした。バイナリinlineも添付上限対象。超過は原文削除や空本文の成功応答に置き換えない。
- 転送エンコード問題、空multipart、本文も添付も分類されない結果を`Incomplete`、parse失敗を`Unparseable`として返す。これは全不正MIMEの完全性判定ではない。charset置換、未知charset、欠落境界で一部だけ復元された結果等を網羅検出する実装は未完了。成功したHTML・添付名・CIDは引き続き未信頼。
- Linux arm64でunit 1 + integration 16 = 17 tests成功。raw / attachmentの実byte境界前後、nested multipart・添付messageの深さ、raw保持、超過を解析前に検出する経路、incomplete / parse失敗を確認。100MiB合算の-1 / 境界 / +1 byteは25MiBの共有borrowed payloadを複数partから参照するunit fixtureで検査（100MiBのallocationや入力からの復号は行わない）。対象clippy `-D warnings`、format、diff、actionlint成功。CI fullのMIME stepへ`--lib`を追加し、budget unitも実行対象にした。
- 制限: rawは既にメモリに読み込まれたsliceであり、入力streamの読み取り制限ではない。decoded / nestingは解析後検査なので解析途中のCPU・メモリ・stack消費を止めない。依存の内部制限で未解析のmessage/rfc822が残る場合の扱い、実復号での100MiB超過、fuzz、3OS runtimeは未検証。製品へ接続する前にこれらを評価する。

- malformed/large MIMEはこのcrateの責務外で、MIME候補の別PoCを行う。未対応IMAP extensionはcapabilityを確認して基本commandへfallbackし、存在しないextensionを仮定しない。
- SMTP final response後の永続化kill / 接続切断によるOutboxのunknown分類、複数RCPTの個別失敗UXを別PoCで確認する。lost / truncated responseで候補がエラーを返すことは確認したが、SMTP `Error`だけで再送可否を決めず、DATA送出境界を記録するoutbox state machineが必要。
- SMTP TLSの接続・認証・固定合成本文送信はPoCで確認したが、OAuth2 mechanism、MIME生成、production adapterの入力検証 / OS trust store / timeout・取消方針は未実装。固定版lettreはTLS handshake errorをconnection errorに包むため、`is_tls()`だけで認証・TLSエラー分類を決めない。TLS検証失敗時のsource chainを評価する必要がある。
- 3OS native compile / runtimeをCIで確認し、license、release/issue healthを再確認してから採用確定ADRへ変更する。
- mailbox name、sequence set、FETCH query、custom command等に任意文字列を連結するAPI面がある。domain adapterで型・validation・constant queryを強制し、UIへ汎用command実行面を公開しない。

## 再評価条件

IDLE cancel後にcommand streamが不整合となる、TLS/STARTTLS境界で安全な認証前提を保てない、必要なUID semanticsを取得できない、または3OSでbuild/runtimeが維持できない場合は候補を棄却し、別clientまたはより低レベルの候補を比較する。
