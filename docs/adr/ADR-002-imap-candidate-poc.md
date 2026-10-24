# ADR-002: IMAP候補ライブラリPoC

- 状態: 採用保留。async-imap 0.12.0でTokio上のXOAUTH2・UID semantics・IDLE取消/polling fallback・rustls implicit TLS/STARTTLSとTLS拒否境界を合成serverで確認したが、FETCH最終statusの欠落、製品上限を超える事前allocation、unsolicited通知queue overflow時の無通知dropが採用blocker。`mail-parser 0.11.9`はmultipart boundary直前のquoted-printable本文を無診断で破損し、debug panicも再現したため製品候補として不採用
- 決定日: 2026-10-20

## 背景

IMAP候補はTLS、SASL XOAUTH2、UID/UIDVALIDITY、IDLEの取消とpolling fallback、保守状況、3OS build、失敗時の扱いを調べてから採用する。実provider account、実サーバ、利用者メールは使わない。

## 候補と比較

| 候補 | 利点 | 残課題 | 現時点 |
|---|---|---|---|
| `async-imap` 0.12.0 | Tokio runtime feature、Authenticatorによる任意SASL challenge/response、UID command API、SELECTのUIDVALIDITY、IDLE handle、汎用AsyncRead/AsyncWrite transport | 既定featureはasync-stdなのでdefault-features=false必須。TLSは外部streamを接続する設計で、STARTTLS upgrade helperはない。upgrade前の認証禁止を呼び出し側で守る必要がある | 優先候補。未確定 |
| `imap-codec` 1.0.0 | transport非依存のDecoder、宣言境界でLiteralFoundによる長さ通知、本文とtagged statusを別応答として保持。MIT OR Apache-2.0 | client / TLS / session管理は提供しない。本文byteを含む入力では宣言長通知が出ず、単純なchunk decodeでは事前上限を保証しない | 宣言長APIの限定PoCを実施。採用未確定 |
| `imap-codec` 2.0.0-alpha.7 / Fragmentizer | 既存のliteral-aware framing、応答保持bytesの上限、同時到着でも宣言通知を先に処理可能。MIT OR Apache-2.0、Rust 1.85+ | プレリリース版。未処理queueは呼出側で投入量を制限。transport / TLS / sessionと失敗時破棄は別途必要 | 上限付きframingの限定PoCを実施。採用未確定 |
| 同期`imap`系client | 同期コードの単純さ | Tauri/Tokio async runtimeとの統合でblocking回避・接続毎workerが必要。今回のPoCで比較試験していない | 未評価 |

## SMTP候補

| 候補 | 利点 | 残課題 | 現時点 |
|---|---|---|---|
| `lettre` 0.11.23 | Tokio async transport、SMTP final positive responseを`Response`として返し、negative responseは`Error::status`・transient/permanentで取得可能。rustlsの暗黙TLS / 必須STARTTLSを合成sinkで確認。MIT、Rust 1.85+ | DATA後の応答不明をunknownへ写像するのは呼び出し側責務。複数RCPTの個別結果は最初の拒否で中断される。production adapter / trust store方針は未実装 | 優先候補。未確定 |

## MIME parser候補の判断

- 固定版`mail-parser 0.11.9`は製品MIME parserとして不採用。合成fixtureでquoted-printable soft break直後がmultipart boundaryとなると、LF / CRLFで本文末尾の1〜2 byteを診断なしに失う。CRLFの短い本文ではdebug panicも起き、UTF-8 raw octet / `=XX`表記の双方で本文欠落やU+FFFD化を確認した。挙動は入力とbuild profileに依存し、既存診断は損失を十分に通知しない。
- この判断は固定した`0.11.9`に限る。別versionや別parserを検証済み・採用済みとは扱わない。既存の`mime-poc` adapterと回帰corpusは原因再現・候補比較専用とし、製品コードへ接続しない。
- 次のMIME作業は個別fixtureの追加ではなく、同じ合成corpusを用いた代替parser候補の一括比較と、raw input / decoded output / nestingの資源上限をどの層で保証するかの設計判断とする。安全な代替が決まるまではAC-04とMIME候補の採用gateを未達のまま維持する。

### 代替parser比較: mailparse 0.18.0

`mailparse 0.18.0`（0BSD、Rust 1.85+）をoptionalな`mime-parser-compare-poc`だけへ追加した。既存AC-04 regression corpusの6種のシナリオに対応する合成入力を用意し、その同じ入力を両parserへ渡す。mailparseでは期待出力、mail-parser 0.11.9では既知の実測出力を照合する。新候補は6ケースすべて期待どおり:

| 既存corpusに対応するケース | 期待出力 | `mail-parser 0.11.9` | `mailparse 0.18.0` |
|---|---|---|---|
| CRLF soft break直後がmultipart boundary | `before` + `second part` | `befo` + `second part`（末尾2字欠落） | 期待どおり |
| LF soft break直後がmultipart boundary | `before` + `second part` | `befor` + `second part`（末尾1字欠落） | 期待どおり |
| soft break後に本文データが継続 | `beforecontinued` + `second part` | 期待どおり | 期待どおり |
| UTF-8 quoted-printable token境界でsoft break | `étail` + `second part` | 期待どおり | 期待どおり |
| multipart/alternative | plain / HTML両partを順に保持 | 期待どおり | 期待どおり |
| Shift_JIS日本語本文 | `日本語` | 期待どおり | 期待どおり |

試験: `cargo test -j 1 -p mail-client --features mime-parser-compare-poc --test mime_parser_compare --locked`。候補比較は専用featureに限定し、native `full`のMIME stepでも既存72 MIME testsとともに実行する設定にした。比較範囲はこの6ケースであり、既存corpus全体を候補間で再生したものではない。

#### malformed / truncated入力の追加比較

既存corpusの3異常形も比較した。`mailparse`はmultipart closing boundaryのない入力をparse成功とし、part本文を返す（固定`mail-parser`は同じ入力で本文を返さない）。不正base64ではmailparseの構造parse自体は成功するが、`get_body()`がdecode errorを返す（mail-parserは`is_encoding_problem`を立てる）。末尾が単独`=`のquoted-printableは両候補とも`=`を落とした本文を正常な文字列として返す。mailparseの`raw_bytes`は各fixtureの入力と一致するが、呼び出し側がdecode errorを扱わず、またはparse成功を完全性と見なせば不完全・損失本文を表示しうる。異常fixtureは比較範囲を広げるもので、望ましい製品契約として認定するものではない。

#### 添付・CID・添付messageの比較

同じbinary attachment入力で、両候補ともtransfer decode後のbytes、標準`filename`、重複`Content-ID`を保持した。RFC 2231の単一extended filenameとcontinuationもmailparseは復号し、UTF-8 octetがsegment境界をまたぐ入力では`日本語.bin`を復元した。既存parserは同じsplit-byte形で`U+FFFD`を含む名前となる。この差はattachment本文bytesの破損ではなくfilename decoding差として分離した。重複CIDは両候補が値を保持するが、曖昧さを診断・拒否する製品policyは呼び出し側で必要。

`message/rfc822`は構造差がある。mailparseは外側partをleafとして返し、decoded raw bodyを取得するが、そのbodyをnested `ParsedMail` treeへ変換しない。mail-parserは`PartType::Message`として内部messageを解析し、nested text bodyへ到達できる。添付EMLを利用するにはmailparse利用側で別途再帰parseを追加し、depth / raw-size budgetを継承させる必要がある。

#### Multipart nesting境界

設計上の最大MIME nestingは30。固定したmailparse 0.18.0は内部`RECURSION_LIMIT=100`を持つが、parse APIから変更できない。同じ単一child multipart fixtureでdepth 30、31、100はいずれもtreeを返し、101は`Recursion limit reached`となった。従って製品上限を31以上で拒否したい場合も、mailparseは少なくともその構造を再帰的にparseした後にしかcallerが深度を数えられない。`message/rfc822`はmailparse tree上leafとなるが、30回の再parseを許可し31回目を開始前に拒否するcaller-budget PoCを確認した。これは再parseごとの深度判定例であり、各段階のraw / decoded byte予算を引き継ぐadapterや製品保証を実装したものではない。内側messageを解析する追加コードでは別途depthとraw budgetを伝播させなければ上限を迂回しうる。この境界testはsmall synthetic inputでの再帰限界を測るだけで、CPU / stack / allocationの安全な上限証明ではない。

#### Decoded bytesの上限境界

不正UTF-8 byteはRust `String`化で1 byteからU+FFFDの3 UTF-8 bytesへ置換される。raw 34 MiBのUTF-8 text入力をmailparseに渡すと、`get_body()`は102 MiBの文字列を返した。raw入力は製品raw上限50 MiB以内だがdecoded上限100 MiBを超え、候補APIにoutput budget引数はない。従ってraw-size gateのみではdecoded output capを保証せず、返却後に長さを検査しても超過分のallocationはすでに発生している。この実測は1入力の置換膨張のみであり、全charset・transfer encoding・複数添付でのpeak memory上限や解析時間を測ったものではない。

#### Multipart part-count amplification

20,000個の1-byte text partを持つmultipartを合成した。raw sourceは1 MiB未満だが、mailparseは20,000個すべてを`subparts` treeとして保持し、先頭・末尾partのbodyを返した。公開parse APIにpart数やallocation予算を指定する引数はない。この結果だけで全入力に対するRAM倍率を決めることはできないが、raw-byte capだけではpart node数を直接制限できず、parse後のpart数検査もtree allocation後になる。従って独立parser案では、全体part-count capをnode生成前に適用する。候補値は4,096 partsとし、利用者向け設定にせず、実装前の容量・互換性判断を要する。

**判断: `mailparse`も採用保留。** 選択したvalid inputとattachment単純形には有望な結果があるが、malformed / truncated MIMEの完全性契約は確立していない。parse成功はmultipart完全性を保証せず、quoted-printable末尾の不完全escapeも検出しない。`message/rfc822`の再帰treeは提供されず、追加parseは呼び出し側責務。組込み再帰上限100は製品方針30より高く設定変更不可で、parse後の検査ではparse-time resource limitを実現しない。fuzz、3OS runtimeも未評価。公開`parse_mail(&[u8])` APIに入力上限引数はなく、treeを返すため上限をparse後に検査するだけでは解析中CPU / stack / allocationの境界を保証できない。呼び出し前raw-size制限に加え、parserの実行中制限と破損診断をどう保証するかが未解決。

### Streaming MIME候補の比較: rmimeparser 0.5.0

`rmimeparser 0.5.0`（LGPL-2.1-or-later）を比較専用featureのoptional依存へ追加した。既存の同一6入力をpush APIへ渡し、4つのquoted-printable / multipartケース、multipart/alternative、Shift_JISのtransfer-decoded octetsを回帰比較した。追加attachment形でもBase64 bytesとRFC 2231 extended filenameを取得できた。候補は合成本文bytesを保持し、`max_buffer_size=16`の設定下でbody callback chunkは16 bytes以下だった。Shift_JISはcharset変換されず原octetsで返るため、製品adapterにはcharset解析・変換が必要。

callback上限PoCでは、handlerがdecoded byte累積100を越える次のchunkを保持前に拒否し、1 byte本文partを20,000個含む入力も32-part limitの33個目で停止した。multipart nestingはcontent-type callbackで計測し、31階層目を検出して停止できた。ただし候補内部ではmultipart boundary文字列をhandler callback前に一つpushするため、厳密な上限では拒否対象の一階層分だけ内部状態が先行する。raw入力上限はparser呼出し前に適用し、製品handlerでpart / decoded / nestingの累積budgetを設ける必要がある。これは合成入力でのcallback契約確認であり、RSS・CPU・全てのdecoder内部allocationを測定したものではない。

異常系では、truncated multipartは未閉鎖boundaryとしてerrorになる。一方、不正base64 `!!!!` はparse成功・空body、末尾単独`=`のquoted-printableはparse成功・`=`欠落となり、いずれも診断を返さない。同じ3結果を公開`MessageParser`経由でも確認し、RFC 5322 wrapperがtransfer decodeの損失を検出・診断しないことを固定した。公開`MessageParser`は`MessageHandler`を`MimeHandler`へbridgeし、RFC 5322 header dispatchとMIME callbacksを一回のstreamで合成する。既存の6入力すべてに`From` / `Subject`を加えた比較testで、Subject callbackとMIME body bytesの保持を確認した。さらに1、2、3、7、31、997 byteの入力chunkで同じ6入力を分割してもSubjectとbodyが一致すること、折り返しheader valueは既定32 KiBちょうどで受理・+1 byteで拒否されること、physical header lineは998文字ちょうどで受理・999文字で拒否されることを確認した。どちらのheader境界も1 byteおよび997 byteのstream入力で同じ結果となった。またfull-message経路でもdecoded byte・part数・multipart nesting budget超過をcallback errorとして伝播し、上限超過データをprobe handlerに保持せず拒否できた。ただしbody callbackは内蔵defaultの最大4096 bytes単位で渡されるため、budget値を超える最後のchunk自体はcallbackに到達する。header callbackのcapability testでは`Subject`と`X-Client-Extension`は通知される一方、`List-Unsubscribe`は通知されず、`MessageHandler`から任意raw headerを網羅取得できない。wrapperには`set_max_buffer_size` / `set_max_header_value_size`も公開されず、内蔵default（body callback chunk 4096 bytes、header value 32 KiB）を製品側から調整できない。callback側のdecoded / part / nesting budget拒否は利用できるが、全header保持・part tree・charset変換・`message/rfc822`再解析のbudget伝播はadapter責務として残る。比較用featureは通常のproduction dependency graphから除外する。

#### 追加候補のソース評価

- `mime-tree 0.5.0`（MIT OR Apache-2.0）はbyte-range tree APIを持つが、固定`mail-parser 0.11`を内部で使用するwrapperであり、今回の既知本文破損を独立したparserで置き換えないため比較対象に追加しない。
- `mailrs-mime 2.0.3`（Apache-2.0 OR MIT）はrecursive `Part` treeを返し、parse中にBase64 / quoted-printableをdecodeする。parse APIにraw / decoded / part / depth budgetがなく、全tree構築後検査となるため採用候補にしない。
- `email-parser 0.5.0`（MIT）は`Email::parse(&[u8])`から`RawEntity`を生成し、transfer decode後のbodyを保持する。multipart解析は子`RawEntity`の`Vec`を作り、decoded本文 / part / depth budgetを受け取るAPIがないため、parse-time resource gateを満たさず比較依存にしない。
- `mailledger-mime 0.0.2`（MIT）はREADMEがparse機能を示す一方、公開Rust API/sourceにはwire EMLから`Message`を構築するparse entry pointを確認できず、model / generation中心と判断。parser候補に加えない。
- `eml-codec 0.4.1`はGPL-3.0-or-later。現在の候補比較では配布条件の適合判断がなく、また上限付きparse contractも未確認のため、依存取得・実行比較を行わない。

#### LGPL-2.1-or-later 配布条件の技術評価

crate manifestと同梱LICENSEは`LGPL-2.1-or-later`を示す。GNUの[LGPL-2.1原文](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)では、Section 6によりアプリ独自の条件でのcombined work配布は可能だが、利用者による自分の利用向け変更と、その変更のdebug目的のreverse engineeringを妨げない条件がある。さらにlibraryの使用告知とlicense copyが必要で、配布形態に応じて、library sourceと変更、static link時に利用者がlibraryを差し替えて再linkできる「work that uses the Library」のobject/source・再構築に必要なmaterialを提供する方法（6a）、または利用者が差し替え可能なshared-library機構（6b）等の条件を満たす必要がある。無料配布でもbinary配布に伴う条件は消えない。

このアプリはTauri/Rustで、Cargo packageは`staticlib` / `cdylib` / `rlib` crate typeを宣言し、CI release計画はmacOS app/DMG、Windows installer、Linux packagesを対象としている。現状、アプリのdistribution licenseはmanifestで宣言されず、利用者へのrelocatable object files・再link用source/toolingの提供、または全対象OSで置換可能なshared-library packagingの仕組みも定義されていない。従って通常のRust static linkingを維持したまま本crateを製品binaryへ含める場合、Section 6aのmaterial提供・notice等を実装できるかを先に決める必要がある。Section 6bを選ぶなら、Tauri bundleでsystem-installed libraryの差し替えが全対象OSで動作する設計・検証が別途必要となる。どちらも現時点では満たしたと判断しない。

これはlicense本文と現行build / release計画の技術的な差分整理であり、法的助言や配布可否の承認ではない。製品採用前に、配布形態、アプリlicense、開発/再link material、EULA、著作権表示を含めて法務またはライセンス担当の確認を得る。確認までは`rmimeparser`をoptionalな内部PoCに限定し、default build / production bundleへ含めない。

**判断: `rmimeparser 0.5.0`は製品候補として不採用（NO-GO）。** callbackでの停止は有望だが、RFC 5322 handlerから任意headerを列挙できず（例: `List-Unsubscribe`がdispatchされない）、公開full-message wrapperからbody chunk / header valueの限度を設定できない。選択した不正Base64 / quoted-printableは成功扱いでデータ損失を通知せず、callback前に内部bufferへ読み込む量も製品budgetと厳密には一致しない。さらにCPU / peak RSS上限・fuzz・3OS runtimeは未証明で、LGPL-2.1-or-laterの配布適合も未判断である。これらは現状のadapter側実装だけでは埋められない採用blockerと判断し、今後は同じ一項目ずつの境界testを追加して判断を先送りしない。依存とcorpusは比較・回帰用途に限りoptional PoC featureに残し、default / production buildには入れない。再検討は、上記の欠落を解消する上流API / 診断改善とライセンス承認が揃う場合に限定する。

今回の比較では、既知の本文破損で`mail-parser 0.11.9`を不採用、parse-time budget APIがない`mailparse 0.18.0`、`mailrs-mime`、`email-parser`も見送り、GPL候補の`eml-codec`はlicense gate未確認のため実行しないと記録した。従って現在の選択肢のうち、製品要件（raw / decoded / part / depthのparse-time制限、損失診断、charset対応）を全て満たし、配布可能性まで確認済みのMIME parserはない。これはPhase 00またはAC-04の完了ではなく、評価済み候補の停止判断である。

## 新規候補の一括hard-gateスクリーニング

crates.ioの`mime parser`、`streaming email parser`、`mail mime`、`message parsing email`、`email mime`、`bounded MIME`、`streaming MIME parser`、`email MIME parser`検索で得た新規候補を公開API・README・依存情報から絞った。既知候補は再評価せず、全corpus比較へ進む前の静的hard gateとした。

| 候補 | 公開情報で確認した点 | 判定 |
|---|---|---|
| [`email-message-wire 0.10.0`](https://docs.rs/email-message-wire/0.10.0/email_message_wire/fn.parse_rfc822.html) | MIT OR Apache-2.0。`parse_rfc822(&[u8])`は入力全体を受け取るAPI。固定`MAX_INPUT_BYTES`は16 MiB、固定multipart depthは100、multipartごとの兄弟part上限は1024。decoded総量・attachment bytes・全体part数のcaller budget APIは公開されない。対応外charsetはlossy UTF-8置換となる（[resource bounds / parser semantics](https://docs.rs/email-message-wire/0.10.0/email_message_wire/fn.parse_rfc822.html)、[input cap](https://docs.rs/email-message-wire/0.10.0/email_message_wire/constant.MAX_INPUT_BYTES.html)、[depth cap](https://docs.rs/email-message-wire/0.10.0/email_message_wire/constant.MAX_MULTIPART_DEPTH.html)）。 | NO-GO。16 MiBはraw 50 MiB要件を満たさず、depth 100は上限30と一致しない。decoded / attachment / global part budgetsも不足し、charset lossも既存fixture要件と合わない。 |
| `daaki-message 0.2.0` | MIT。公開parse APIは`parse_email(&[u8]) -> Result<ParsedEmail, Error>`のone-shot形式。READMEはfull MIME対応を掲げるが、README/APIにparse-time byte・part・depth budgetは記載されない（[API](https://docs.rs/daaki-message/0.2.0/daaki_message/fn.parse_email.html)、[README](https://crates.io/crates/daaki-message/0.2.0/readme)）。 | NO-GO（静的gate）。callerが資源上限を設定できる契約を確認できず、全corpus試験や依存追加には進めない。 |
| `br-email 1.2.23` | MIT。READMEの`Mail::analyze(data, false)`はraw `Vec<u8>`を解析する全体入力API。IMAP/POP3/SMTPを含むumbrella crateで、公開READMEにMIME parse budgetは示されない。 | NO-GO（静的gate）。上限付きparser APIを確認できず、parser以外のclient機能も候補要件外。 |
| `email-extract 0.1.0` | MITだが`mailparse ^0.16`上の抽出wrapperで、独立parserではない。 | NO-GO。既評価`mailparse`のparse-time budget欠落を解消しない。 |
| `base64-ng-mime 2.1.0` | RFC 2045 Base64 transfer-bodyを扱うbounded helper。 | MIME/RFC 5322 message parserではないため代替候補ではなく、将来の独立parser設計での部品候補に留める。 |

このスクリーニングは公開情報による静的gateであり、上記の不通過候補を同一corpusへ追加していない。新規依存・Cargo設定変更もない。通過候補は0件。既知候補の評価結果と併せても、現時点で製品要件に合格するparserは確認できない。ライセンス表記はcrates.io上のメタデータ確認であり、配布可否の法的承認ではない。

### 独立bounded parser / adapterの設計案

現PoCの根本問題は、[`mime_poc::parse_with_diagnostics`](../../src-tauri/src/mime_poc.rs)が`MessageParser::parse`で全part treeとdecoded bodyを構築した後に`validate`でdecoded / attachment / nesting上限を検査する点にある。raw上限はparse前に適用するが、他の上限は超過allocation後の拒否である。先行preflightを加えて既存parserを再実行する方式も、二重走査と無制限tree allocationを残すため採らない。

1. 既存のbounded source readerがraw ≤50 MiBをparse前に保証する。parserはcaller所有の`&[u8]`を借用し、raw全体や各part bodyの複製を作らない。
2. `mail-parser`等の全tree APIではなく、RFC 5322 header / MIME boundaryを走査する独立scannerを使う。multipart階層は明示stackで保持し、31段目をpushする前に拒否する。part本文はraw内のrangeとして参照し、転送復号の出力だけをbounded sinkへ逐次書く。
3. decoded byte数はtransfer decodeとcharset変換の両方の出力時に加算する。`checked_add`後にaggregate ≤100 MiB、各attachment ≤25 MiBを検査し、超過byteをsinkへ書く前にerrorにする。part数はdescriptor生成前に計上する。全message共通の上限は4,096 parts（multipart container、leaf、`message/rfc822`を数え、attached message内部にも同じcounter / depthを伝播）とする。
4. headersはraw range参照を基本とし、unfolded valueなど保持が必要な値はbyte上限付きで扱う。上限はphysical line ≤998 octets、unfolded value ≤32 KiB、message全header block ≤1 MiBとする。
5. Base64 / quoted-printable / charset変換は固定小chunkで処理する。invalid / truncated transfer data、unsupported charset、header / boundary異常は明示診断または`Incomplete`で返し、parse成功の形で黙ってbyteを削らない。失敗時も元rawの所有権はcallerに残し、部分結果を完全な本文として保存しない。
6. 結果は全recursive treeでなく、bounded part metadataとplain / HTML body / attachment sinkへのhandleからなるflat modelとする。HTMLは未信頼データのまま扱い、sanitization / sandboxはこのparserの責務に含めない。

設計検証では既存AC-04 corpusを維持し、budgetの直前・一致・超過、20,000-part amplification、31-depth、`message/rfc822`経由の累積budget、charset expansion、全transfer encodingの切断・不正値を、処理中に超過出力を生成しないことまで測る。任意fragment境界による結果不変性、property/fuzz、releaseでのCPU・peak RSS、3OS CIも採用gateにする。Rust実装はblocking workとして扱い、chunk / part境界で協調停止可能にする。PoC依存はoracleと回帰比較に留め、bounded guaranteeを単独で証明できるまでproduction parserへ接続しない。

ユーザー確認により上記のpart数 / header上限を設計契約として確定した。これはparser採用やproduction接続の承認ではない。MIME part / boundary scannerとparse-time part/depth accountingの初期sliceを実装し、transfer/charset decodingと診断を次段階とする。配布形態・license適合は実装評価と混ぜず法務またはライセンス担当レビューへ分離する。AC-04 / MIME採用gateは未達のままとする。

#### 最初のbounded scanning slice

[`mime_bounded_poc`](../../src-tauri/src/mime_bounded_poc.rs)を依存なしの`mime-bounded-poc` feature限定で追加した。既存`mime-poc` featureからも利用でき、raw 50 MiB定数を共有する。RFC 5322 section scannerはparse前にraw上限を検査し、最大998 octetsのCRLF / LF physical header行、1 MiBのheader block（空行separatorを含む）、32 KiBのRFC unfolding後field valueを処理中に拒否する。bare CR、field-name token外byte、先頭continuation、header/body separator欠落も明示errorになる。

結果はheader descriptorをtree/vectorとして保持せず、caller-owned rawのheader/body rangeとcountのみを持つ。`headers()`はrangeを再走査してheaderを遅延列挙し、`unfolded_value()`は最大32 KiBの出力を生成する。foldではCRLF / LFのみを除去してcontinuationのWSP列を保持する。

`MimeDocument::parse`を追加してRFC 5322 entityをiterativeに走査する。MIME partはflat descriptor（header/body raw range、parent index、nesting depth、kind）のみを4,096件まで保持し、全体part上限超過を次part descriptor生成前に拒否する。multipart境界はraw bodyを行単位で走査し、boundary-prefixだけの行をdelimiterと誤認しない。closing delimiter欠落、不正boundary / Content-Type、未完了childは明示error。multipart containerと`message/rfc822`の入れ子を同じ30-depth budgetへ算入する。body rangeは区切りboundary直前のCRLF / LFを除き、`MimeDocument`経由でrawへbounds-safeにアクセスする。nested entityのheader blockも集計し、全体1 MiBを超えた時点で拒否する。

このsliceは本文をopaque borrowed rangeで返し、transfer decoding、charset対応、decoded total 100 MiB、attachment 25 MiBとloss診断は未実装である。従ってbounded structural scannerのPoCであり、表示用MIME parserではない。production/default buildへ接続しない。

検証時点の構造scanner test結果: `cargo test -j 1 -p mail-client --features mime-bounded-poc --lib --locked`で10 tests、比較suiteでunit 15 + regression 72 + comparison 19 = 106 tests成功（当時のbounded unit 10件を含む）。998 octets / +1、32 KiB / +1、header block 1 MiB / +1、raw 50 MiB / +1、4,096 parts / +1、nesting 30 / +1、`message/rfc822` nesting、boundary-prefix、closing boundary欠落、borrowed body ranges、malformed Content-Typeを確認。`cargo clippy -p mail-client --lib --features mime-bounded-poc --locked -- -D warnings`、`cargo fmt --all --check`、`git diff --check`成功。`mime-bounded-poc` normal dependency treeには`mail-parser` / `mailparse` / `rmimeparser`を含まない。Windows/macOSのこのPoC CIは未実行。AC-04未達。

### bounded transfer-decoding slice

`MimePart`は`Content-Transfer-Encoding`を構造走査時に検査し、missingを7bitとして扱う。単一・重複・不正fieldを区別し、重複/不正fieldは明示error、未知tokenはdescriptorに保持してdecode時にunsupportedとして返す。`decode_part_to`は固定1 KiB bufferを通してsinkへstreamし、各出力octetをbuffer投入前に共有`DecodeBudget`（decoded合計100 MiB）と任意の当該attachment上限25 MiBへchargeする。callerはattachment該当性を渡し、全part共通のbudgetを共有する。multipart containerの直接decodeは禁止。

実装transfer encodingは7bit（high-bit octet拒否）、8bit/binary（identity）、Base64（MIME whitespaceを読み飛ばし、paddingとpad-bitを検証）、quoted-printable（hex escapeとCRLF/LF soft break）である。malformed/truncated inputは成功形の出力に置き換えない。sinkへ既にprefixを書いた後のエラーもあり得るため、callerは失敗時にsink出力をdiscard/rollbackし、途中までchargeされたbudgetも破棄する必要がある。decoderはcharset変換しない。encoded `message/rfc822`をdecodeしてからnested structural scanする統合も未実装であり、decoderをproduction接続しない。

検証: bounded unit 14件成功、比較suite unit 19 + MIME regression 72 + comparison 19 = 110件成功。Base64/QP正常・異常、未知/重複CTE、7bit high-bit、aggregate budget累積、attachment budget、上限超過前のsinkへの未書込み、multipart decode拒否を確認。`cargo clippy -p mail-client --lib --features mime-bounded-poc --locked -- -D warnings`と比較integration Clippy（`-D warnings`）成功。AC-04未達。

### bounded charset-decoding slice

bounded feature限定のoptional依存として`encoding_rs 0.8.42`（manifest上で完全固定）を追加した。依存元のcrate metadataは`(Apache-2.0 OR MIT) AND BSD-3-Clause`。この依存はdefault buildへ有効化していない。`Content-Type`からcharset parameterを保持し、重複・空・不正tokenをparse時に拒否する。text/plain等のtext媒体用`decode_text_part_to`は宣言labelを`for_label_no_replacement`で解決し、未知label / replacement encodingをunsupported errorとする。charset省略時はUTF-8。encoding_rsのincremental `decode_to_utf8_without_replacement`を使い、malformed / truncated sequenceをU+FFFDへ置換せずerrorにする。

transfer-decoded各octetはcharset変換器の固定1 KiB input bufferへ入れる前に累積decoded budgetへchargeし、生成UTF-8各octetもsink write前に同じ累積100 MiB budgetへchargeする。attachment上限25 MiBは変換後UTF-8出力に適用する。decoder output bufferは固定4 KiB。charset入力境界を跨ぐShift_JIS multibyte sequenceとWindows-1252の1→3 byte展開を試験し、transfer+charset両段のbyte数を予算計上することを確認した。UTF-8 / Shift_JIS / UTF-16LE malformed/truncated sequences、unsupported labels、非text part、重複charsetもerrorとなる。charset/transfer error後にsinkへ部分出力済みの場合があり、budgetも処理済みbyteを保持するため、callerはsinkをdiscard/rollbackしbudgetを破棄する。

検証: bounded-only unit 17件、比較suite unit 22 + MIME regression 72 + comparison 19 = 113件成功。charset展開のlimit一致 / 超過、予算超過前の未書込み、buffer境界跨ぎも確認。bounded-only Clippyおよび比較test Clippyは`-D warnings`成功、fmt / diff check成功。bounded normal dependency graphに`mail-parser` / `mailparse` / `rmimeparser`を含まない。encoded `message/rfc822` decode→nested scan統合、包括的loss diagnostics、fuzz、CPU/RSS計測、Windows/macOS PoC CI、license配布レビューは未実施。production/default buildへ接続しない。AC-04未達。

### encoded `message/rfc822` nested scan

structure scannerは`message/rfc822`を検出しても、CTEが7bit / 8bit / binaryのidentityの場合だけそのraw bodyを直ちにnested scanする。Base64 / quoted-printable等のencoded bodyは転送encodingのままscanせず、`decode_encapsulated_part_to`でbounded transfer decodeしてからcallerが`parse_nested`へ渡す。root documentと全nested documentは同じ`StructureBudget`を使い、part総数・nested header総量・absolute nesting depthを累積する。本文のdecodeにも同じ全体`DecodeBudget`を伝播する。失敗時は部分出力と各budgetを破棄する。

これは明示的な逐次APIであり、`MimeDocument::parse`がencoded nested messageを自動decode / scanするわけではない。callerはdecode済みバッファの所有権と寿命を維持し、そのsliceを借用するnested documentを使い終わるまで保持する必要がある。nested MIMEの全part decode / 添付分類はcallerが行う。境界試験ではBase64のattached messageをdecodeし、nested textをshared budgetでscan・decodeした。shared part/header limits、depth 30、nesting 31拒否、通常のidentity nested message動作も確認した。

検証: bounded-only unit 19件、比較suite unit 24 + MIME regression 72 + comparison 19 = 115件成功。bounded-only ClippyとMIME comparison target Clippyは`-D warnings`成功、fmt / diff check成功。実メール、fuzz、3OS CI、peak RSS / CPU証跡、production接続は未実施。AC-04未達。

### decode diagnostics slice

`decode_text_part_to_with_diagnostics`は、charset parameter欠落時にUTF-8 defaultを使った事実と、生成したUTF-8 streamにU+FFFDが存在した事実だけを返す。U+FFFDの存在だけでは変換損失を断定できないため、診断型もlossと表現しない。malformed charset / transfer sequenceやunsupported encodingは従来どおりエラーであり、置換して成功にしない。U+FFFD byte sequence検出は固定状態のみで、charset出力chunkを跨いでも動作する。変換の成功時だけ診断値を返すため、エラー後のsinkとbudgetは呼び出し側で破棄する。

この診断は完全なloss / MIME quality reportではない。RFC 2047 header / RFC 2231 parameter decode、charset aliasの信頼度、unknown header reporting等を網羅しない。追加したQP観察は、LF単独のsoft breakとphysical line末尾に未encodeで残るSP/TABをbounded flagとして報告する。本文は修復・正規化せずdecoder既存出力を保持する。bounded-only unit 21件および比較suite unit 26 + regression 72 + comparison 19 = 117件で、default UTF-8と明示UTF-8を区別し、合法なsource U+FFFDをchunk境界越しに検出してもlossと主張しないこと、QP異常を報告しつつsource octet由来出力を変更しないことを確認した。AC-04未達。

検証: `cargo test -j 1 -p mail-client --features mime-parser-compare-poc --lib --test mime_candidate --test mime_parser_compare --locked`（unit 5 + regression 72 + comparison 19成功）、`cargo clippy -p mail-client --test mime_parser_compare --features mime-parser-compare-poc --locked -- -D warnings`、`cargo fmt --all --check`、`git diff --check`。`cargo tree -p mail-client --edges normal --no-default-features --locked`では3 MIME parser候補がdefault dependency graphに存在しない。3OS CI未実行。

### bounded MIME fuzz harness

`src-tauri/fuzz`を独立workspaceにし、`libfuzzer-sys`と固定`encoding_rs`を使う`mime_bounded` targetを追加した。対象moduleをsource pathで直接compileするため、fuzz targetがTauri / WebViewの依存graphを引き込まず、製品のdefault featureや依存lockfileも変更しない。任意byte列をRFC 5322 / MIME parseへ渡し、成功時にpart header/body rangeとparent indexを検査し、leafのtransfer decodeおよびstrict text decodeを`io::sink()`へ試す。初期corpusは合成multipart、quoted-printable text、identity `message/rfc822`を含む。

検証: Linux arm64 nightlyで、最大65,536-byte入力・2秒per-input timeout・768 MiB RSS limitによりfuzzを2回連続実行した。1回目は121秒で5,799,790 inputs、coverage counter 1,270 / feature 6,999、peak RSS 441 MiB。拡張した一時corpusを引き継いだ2回目は61秒で1,912,986 inputs、coverage counter 1,276 / feature 7,344、peak RSS 406 MiB。合計182秒で7,712,776 inputs、crashなし、RSS limit未到達。2回目のprocess resource usageはwall 61.3秒に対しchild user CPU 56.6秒 / system CPU 4.6秒、31,360 exec/s。これらはLinux arm64 harness processの限られた実測であり、parser単体やproductionのCPU / memory上限、3OS耐性の保証ではない。curated seedのみの`-runs=1` replayも成功。`cargo check --manifest-path src-tauri/fuzz/Cargo.toml --locked`、fuzz manifest Clippy `-D warnings`、bounded unit 21件、format / diff check成功。より長いfuzz、3OS runtime、CI接続、配布license review、production接続は未実施。AC-04未達。

### MIME PoC license / distribution review

`cargo metadata --all-features --locked`と各固定crateのregistry sourceを照合した。これはSPDX metadata・同梱license file・featureによる依存分離の確認であり、全アプリのSBOM監査、法的意見、配布承認ではない。

| Crate | 固定版 / 位置付け | Cargo license metadata | source / distribution上の確認 |
|---|---|---|---|
| `encoding_rs` | 0.8.42、`mime-bounded-poc`でoptional | `(Apache-2.0 OR MIT) AND BSD-3-Clause` | sourceにApache、MIT、`LICENSE-WHATWG`とWHATWG由来データのCOPYRIGHTがある。BSD 3-Clauseのデータ帰属・条件も配布noticeへ含める必要がある。 |
| `mail-parser` | 0.11.9、`mime-poc`でoptional | `Apache-2.0 OR MIT` | registry crateのREADMEは上流LICENSE-APACHE / LICENSE-MITを参照するが、配布crate rootには両本文がない。現状はparser制約により製品不採用。将来採用を再検討する場合、同じ上流tagのlicense本文を明示的に同梱する。 |
| `mailparse` | 0.18.0、比較featureのみ | `0BSD` | crateに0BSD LICENSE本文あり。optional比較依存で製品/default graphには含めない。 |
| `rmimeparser` | 0.5.0、比較featureのみ | `LGPL-2.1-or-later` | crateにLGPL-2.1本文あり。default / production buildには含めず、製品へリンク・配布する選択はしない。将来再検討するならリンク形態、変更有無、対応source / relink提供、noticeを含め法務確認が必要。 |
| `libfuzzer-sys` | 0.4.13、独立fuzz workspaceのみ | `(MIT OR Apache-2.0) AND NCSA` | wrapper側のMIT / Apache本文を含む。READMEは同梱`libfuzzer/` sourceをNCSAとしている一方、NCSA license本文はcrate rootにない。LLVM exception付きApache SPDX headerもvendor sourceに存在する。fuzz binaryは製品へ配布しない。 |

bounded-onlyの通常依存treeには`encoding_rs`とそのMIT / Apache系補助crateのみが入り、3 parser候補は入らない。`mime-poc`と`mime-parser-compare-poc`は評価用optional featureで、production候補承認ではない。現時点でアプリが当該PoC featureなしで出荷される限り、PoC parser・fuzz runtimeはアプリ成果物に含めない。もしbounded MIME featureを製品へ採用する場合は、少なくともApache-2.0またはMITの選択条件に加えてWHATWG BSD 3-Clause noticeを含むNOTICE集約を追加し、全対象target / featureのSBOMと全推移依存のlicense reviewをやり直す。mail-parserの上流license本文を含まない現crate package、およびLGPL比較crateの扱いを自動的に許可済みと解釈しない。正式な配布承認は未了。

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
| STARTTLS authenticated EXAMINE / UID FETCH session（00C / AC-04・06・08前提） | 同一の合成sessionでplaintext greeting → tagged STARTTLS OK → rustlsの通常証明書 / hostname検証 → TLS上のXOAUTH2 challenge/response → EXAMINE "INBOX" → UIDVALIDITY=4242 / UIDNEXT=10 → UID FETCH 8 (UID FLAGS BODY.PEEK[])を確認。FETCH応答ではUIDが1個だけ8であること、BODY[]全bytesが合成SOURCEと一致すること、一致tagのOK completionを明示検証してからLOGOUTする。別4ケースでtagged NO / BAD、別tagのOK、本文literal後の完了応答なしEOFは成功扱いにせず、完全本文をprovisionalに保ったまま接続を破棄し、後続commandを送らない。異常caseを含めLinux arm64でIMAP candidate 10 tests成功、対象clippy `-D warnings` / format / diff成功。これは候補session連携の小さい合成literal試験であり、既存bounded receiverとは未接続。async-imap内部のliteral読込上限、UIDVALIDITY変更時の同期処理、account/folder scope、実サーバ、3OSは未検証。 |
| STARTTLS authenticated IDLE notification / cancellation / timeout / DONE race / keepalive / burst後UID・FLAGS再照合（00C / AC-06・08前提） | 同一の合成TCP/TLS sessionでSTARTTLS → 通常の証明書 / hostname検証 → 合成XOAUTH2 → CAPABILITY(IDLE) → READ-ONLY EXAMINE INBOX / UIDVALIDITY → IDLEを確認。合成`* 1 EXISTS`を`IdleResponse::NewData`で受け取り、DONE後に同じsessionでIDLEへ再入できる。DONE受信直後・tagged completion前に到着する`* 2 EXISTS`と連続100件を注入し、capacity 100の`session.unsolicited_responses`にはExists(2..=101)だけが残り、101件目のExists(102)はoverflow時に`handle_unilateral`が`try_send`失敗を無視して捨てることを再現。overflow後のNOOPで最新`EXISTS=102`、初回固定`UID SEARCH ALL`ではUID 1..=102を返す。その後UID 50がFETCH前に消失する競合を注入し、`UID FETCH 1:102 (UID FLAGS)`が残り101 UIDへのFLAGSとtagged OKを返すこと、UID 50のFETCH応答がなく、続く完全`UID SEARCH ALL`でもUID 50が不在であることを確認。UID 1のSeen、UID 2のflagなし、UID 102のFlagged、UID重複なしを検査。続いて高水準`uid_fetch`のtagged NOが空streamとなる欠陥、raw commandによるtagged OK / NO判定、partial FLAGS後のNOと完全集合未満を確認。raw経路でのstatus / UID照合手段はあるが、実同期層でのUID消失処理・DB永続化・差分更新・UIDVALIDITY照合は未実装であり、overflow後の再同期責務と高水準FETCH status欠落は採用判断の未解決事項。次のIDLEではstop source drop後に`ManualInterrupt`、3回目は無通知で`Timeout`を確認。さらに500ms waitの初回開始250ms後に合成`* OK` keepaliveを送り、その400ms後（初回開始から650ms）にEXISTSを送るとtimeoutせず`NewData`となり、keepaliveで期限がリセットされることを確認。全DONE後に同じselected sessionでNOOP / LOGOUTが成功し、peerがtagとcommand順を検査。Linux arm64で個別test・IMAP candidate 11 tests・対象clippy `-D warnings` / format / diff成功。本testを含む3OS CI、実サーバ、製品同期処理、account scope、production connection managerは未検証。 |
| STARTTLS bounded FETCH中断 / 異常 | 追加2 tests。STARTTLS昇格後にliteral over 50 MiB+1・literal途中EOF・literal途中stallのdeadline / cancel・最終status途中stallのdeadline / cancelを検証。上限超過でheaderのみ保持、EOF / literal中断でheader + 7 bytesを回収しprovisionalなし、最終status中断では完全SOURCEをprovisional、未完statusをprefixとして回収。全失敗でTLS接続を破棄し後続commandなし。証明書 / hostname検証維持。server→clientのoneshot後、cancelに50ms処理猶予を置き、既処理prefixを確認。deadlineはTLS upgrade後の1秒。初回はoneshot配置のcompile失敗と、処理前cancelでprefix空となる試験失敗を修正 |
| STARTTLS統合後チェック | Linux arm64でunit5 + IMAP49 + MIME42 = 96 tests成功。対象clippy `-D warnings` / format / diff成功。既存拒否・未信頼証明書・hostname mismatch試験も維持。製品コード・依存・workflow変更なし。3OS・実サーバ未実施 |
| 上限付きFETCHのSTARTTLS昇格（AC-04 / AC-06前提） | Linux arm64でIMAP47 tests中に正常1経路、STARTTLS拒否・未信頼証明書・hostname mismatchの否定3経路を確認。plaintext greeting → async-imapのtagged STARTTLS OK → raw TCP stream upgrade → 通常のrustls検証 → bounded FETCH。TLS前のFETCH / 認証なし、否定経路にplaintext fallbackなし。正常経路はSOURCE全bytes・tagged OK・MIME解析と同じTLS receiverでのNOOP成功。TLS identity errorがあればFETCHを送信せず閉じる。テスト限定・合成peerであり認証/mailbox選択や実サーバではない |
| 統合後チェック | `cargo test -j 1 -p mail-client --features imap-poc,mime-poc --lib --test imap_candidate --test mime_candidate --locked --quiet`: unit5 + IMAP47 + MIME42 = 94 tests成功。対象clippy `-D warnings` / format / diff成功。3OS未実行、依存・製品コード・workflow変更なし |
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

### UID FLAGS取得のtagged失敗status

- 既存のSTARTTLS IDLE / UID再照合fixtureへ、FLAGS取得時にサーバがtagged `NO`を返す経路を追加。`Session::uid_fetch`は`Ok(stream)`を返し、streamは空終端となって拒否statusを呼び出し側へ伝えない。直後のNOOPが成功するため、session同期自体は保たれるが、空結果とcommand拒否を区別できない。
- 同じfixtureでraw `run_command` / `read_response`により、102件のUID/FLAGS応答に加えて一致tagged OKを検証できること、tagged NOを拒否として識別した後に同じsessionのNOOPが成功することを確認。さらに1件だけのpartial FLAGS応答後にtagged NOを返す異常caseで、取得件数が完全集合より不足することと拒否statusを検証してからNOOPを実行する。候補API内にstatusを観測する代替経路はあるが、応答ごとのUID/FLAGS検証、tag一致、completion判定、全UID集合との照合をcallerが実装する必要がある。
- 高水準`uid_fetch`単独利用は採用blocker。raw経路は合成testでのみ確認し、製品同期adapter・失敗時の状態管理・DB更新としての回避実装は未着手。
- 新epochのUID 50を対象に高水準`uid_fetch`へpartial FLAGS itemだけを返し、tagged completion前にTLS closeするcaseも追加。APIはitemをyieldした後、missing completionをerrorにせず通常stream終端として示す。itemが届いたことを完了扱いできず、全応答はprovisionalのまま一致tagged OKとUID集合の完全性が必要。raw APIによる明示status確認が必要という採用blockerを強める再現であり、製品同期のstaging / commit契約は未実装。
- 同じ新epoch fixtureで高水準`uid_search("ALL")`にpartial SEARCH応答（UID 49, 50）の後tagged NOを返すと、エラーでなく部分HashSetが返ることを再現。共通raw UID SEARCH helperはpartial UID集合を保持して一致tagged NO / BADを個別に拒否分類し、foreign-tag OK後に一致tagged BADが続く別caseは`WrongTag`として不採用にする。正規の空`* SEARCH`+tagged OKは空集合として受理する一方、SEARCH dataのないtagged OKは`MissingSearchData`として拒否する。またtagged OK後でも重複UIDまたはUID 0を含む集合は拒否する。後続の正常検索はUID 50のみを返す。したがって完全集合照合に高水準`uid_search`だけを使うのも採用blockerであり、raw経路側で正しいtag・status・UID集合を一緒に検証する必要がある。
- 独立した合成stream testでpartial `* SEARCH 49 50`後のEOFを注入。高水準`uid_search`は部分HashSetを成功形で返す一方、raw readerでは一致tagged completion前に`None`を観測する。完全UID検索結果とcheckpointは一致tagged OKまでcommit不可。production adapterのrollback / checkpoint transactionは未実装。
- 同じSTARTTLS sessionでINBOXを再EXAMINEし、UIDVALIDITY=4242から4243への変更を検出後、新epochの`UID SEARCH ALL`がUID 50のみを返すこと、同じ数値UIDのFLAGSを新epochの応答として取得できることも確認。これはUIDVALIDITYと再照会APIのtest fixtureであり、旧UID参照 / pending operationの無効化・DB transaction・AC-08全体の収束実装ではない。

### transport I/O障害とInterrupted時の取消公平性

- test限定の固定UID FETCHへ合成AsyncRead / AsyncWrite transportを追加。送信buffer・read / flush回数・Dropを共有観測し、新規4 testsの計8ケースを実行する。実TCP / TLSの障害注入ではなく、wrapperが受け取るI/O結果の契約試験。
- short writeは最大3 bytesずつ返し、7 bytes受理後のBrokenPipe / 0-byte write（Tokio write_allがWriteZeroへ変換）、全command送信後のflush BrokenPipeを注入。Write(ErrorKind)・正確なcommand prefix・読込0回・Dropをassertし、追加送信・再送を許容しない。writeが7 bytes後にPendingとなる場合もcancel / deadlineで中断し、flush / readが行われずtransportがdropされることを確認する。commandが一部送信済みでも接続を返さない。
- 途中literalと、完全SOURCE後の途中最終応答へConnectionResetを注入。Receive(Io(ConnectionReset))・処理済みwire prefix全一致を確認し、後者だけ完全SOURCEをprovisionalとして保持する。内部errorの合成private文字列をDebugへ出さず、原因kindと長さのみ表示する。
- current_thread executorで、途中literalに続く有限10,000回のInterruptedと、read回数2以上を待って取消を通知する別taskを使用。Interrupted後のyieldにより取消taskが実行され、fixtureを使い切る前にCancelledとなること、prefix全一致・送信command 1回・Dropをassertする。無限ループfixtureやwall-clock速度だけに依存した公平性判定は使わない。
- 既存実装の変更は不要。Linux arm64でIMAP44 tests、対象clippy `-D warnings` / format / diff成功。MIME単独・unit・3OSは今回未再実行。製品コード・依存・workflow変更なし。単一呼出内での追加送信なしを確認しただけで、再接続・長期間のretry・実TLS write障害・task abort時のデータ回収を保証しない。採用gate・Phase 00は未完了。

### FETCH外側取消でも処理済みwire prefixを回収

- privateなBoundedReceiver::read_responseはreceiverと進行状態を借用する。既存receiveは引き続きreceiverを所有し、失敗時に回収prefixだけを返して接続をdropするwrapper。固定UID FETCHはreceiverを外側に所有して借用受信を呼ぶため、外側selectがwrite / read / flushを中断してもreceiverのframing stateを調べてから破棄できる。private借用APIをエラー後の接続再利用に使わない。
- 読込stepを開始したかを外側へ記録し、正常応答の検証後にはresetする。開始前中断では過去の応答bytesを回収せず空、完全本文受信後の空の完了待ちでも過去の本文応答をprefixとして二重返却しない。完全本文は別のprovisionalに保持する。protocol error時の処理済み応答もwire prefixとして保持可能になったが、成功本文への昇格はしない。
- 新規1 testの12ケースは、途中literal（header + SOURCE先頭7 bytes）と途中最終応答（F0001 OK incomplete）それぞれのdeadline / cancelをpeer write分割1 / 17 / 4096 bytesで注入。通常の証明書・hostname検証を有効にしたloopback TLSで、wire prefix全一致と接続終了・後続command 0 bytesを確認する。前者はprovisionalなし、後者は完全SOURCEもprovisionalで同時保持する。既存の完全本文後に何も届かない中断ケースもprefix空を追加assertした。
- 最初の途中最終応答fixtureはシナリオ分岐の内側へ誤配置され実際には送信されず、prefix全一致assertが失敗した。fixture配置を修正後、Linux arm64でunit5 + IMAP40 + MIME42 = 87 tests、対象clippy `-D warnings` / format / diff成功。製品コード・依存・workflow変更なし。
- 解消したのは限定PoCの外側selectで取消された借用受信の処理済みprefix回収だけ。TLS内部・framing未処理queueのbytes、wrapper自体のdrop / task abort、原文永続化、実サーバ・3OS、account / folder / UIDVALIDITYや通知配送は未保証・未実装。既存async-imap内部bufferの回収を修正したわけではない。採用保留・Phase 00未完了を維持する。

### 複数FETCH応答をまたぐ本文保持と整合性

- 既存test限定の固定UID / tag統合fixtureへ応答列シナリオを追加。新規2 testsは7種類の応答列をpeer write分割1 / 17 / 4096 bytesで実行し、計21ケースを検証する。TLSのread境界がwrite分割と一致する保証はなく、framingの厳密な入力分割試験は既存probeが担う。証明書・hostname検証は有効のまま。
- 正常6ケースはUID 8のFLAGS-only応答を本文の前または後に送信する。本文がまだないFLAGS応答だけでMissingBodyにせず、一致tagged OKまで待ってSOURCE全bytesとMIME解析、同じreceiverでのNOOP成功を確認。FLAGSは受入可能な属性として検証するだけで、DBへの反映や同期競合処理を実装していない。
- 異常15ケースは完全本文の後、別FETCHで第2本文（異なる9 bytes） / UID 9のFLAGS / UIDなしのFLAGS / BODY[]<17> / BODY[] NILを送信し、続いて一致tagged OKを送る。不正な応答を最終OKで成功へ覆さずUnexpectedResponseとし、先に受け取ったSOURCEをprovisionalとして全bytes保持する。後の不正本文で上書きせず、peer側で接続終了と後続command 0 bytesを確認。NILが最初に届く場合の分類や全ての属性組合せを網羅した試験ではない。
- 既存check_responseの判定変更は不要だった。変更はfixtureと回帰試験に限定。Linux arm64でIMAP39 tests、対象clippy `-D warnings` / format / diff成功。初回clippyのenum共通suffix警告を命名修正で解消。MIME単独・unit・3OSは今回未再実行。製品コード・依存・workflow変更なし。
- 別UIDの合法unsolicited応答も拒否する限定PoCであり、通知配送を実装したとは扱わない。account / folder / UIDVALIDITY、認証・mailbox選択、実サーバ・3OS、厳密な資源制限などの採用gateは引き続き未達。Phase 00未完了。

### 上限付き受信からFETCH最終応答確認までの統合

- test限定checked_fetchがBoundedReceiverを所有し、固定tag F0001 / UID 8のBODY.PEEK[]要求をwrite / flushする。固定2.0.0-alpha.7の公開Response / Data::Fetch / MessageDataItem / Status::Tagged / StatusKindを配布sourceで確認し使用。UIDはちょうど1個で8、BODY[]はsection / originなし・非NIL・重複なしを要求し、一致tagged OKと本文を確認後だけreceiverと本文を返す。未知応答や未対応属性はfail-closedであり、合法unsolicitedを配送するclientではない。独自wire parserや文字列によるstatus判定は使わない。
- 新規4 testsは正常3ケース（peer write分割1 / 17 / 4096）・応答異常12ケース・完了待ち中断2ケース・開始前中断2ケース。検証済みlocalhost証明書のloopback TLS上で、正常時はSOURCE全bytesとMIME解析、返却接続でのF0002 NOOPと応答一致を確認する。NOOPはFETCH成功の代用ではない。fixtureは認証・mailbox選択を省略した合成peerで、実IMAPセッションの状態遷移やSeen不変は証明しない。
- NO / BAD、別tag、UID不一致 / 欠落 / 重複、同応答内の本文重複、partial origin 0、本文なし、raw上限超過、完了応答前EOF、literal途中EOFを明示的に失敗させ、peerで後続command 0 bytesと接続終了を確認。完全本文はNO / BAD / 別tag / 本文重複 / 完了前EOF / 完了待ちdeadline・cancelでもprovisionalとして保持するが完全cacheへ昇格しない。不正UID・partial・上限超過・途中literalでは完全本文を返さない。上限超過は宣言headerだけ、途中EOFはheader + 本文7 bytesのwire prefixを完全一致で確認する。Debugは原因・byte数のみ。
- 外側selectはwrite / flush・受信を含む全操作へabsolute deadlineと取消を適用する。開始前のready取消 / 期限切れではコマンド0 bytesと接続終了をDuplexStreamで確認し、両方readyなら取消優先。失敗時は接続を返さずdropし、曖昧な途中writeを同じ接続で再利用しない。完全本文保持はselectの外側だが、取り消されたreceive future内部のwire prefix回収、wrapper自体のabort / drop、write途中中断の実TLS注入は未保証・未検証。
- 最初に追加したpreflight testはinner itemとして実行されずclippyでも失敗したため、module scopeへ修正し実行数37件を確認。Linux arm64でunit5 + IMAP37 + MIME42 = 84 tests、対象clippy `-D warnings` / format / diff成功。既存候補の欠陥再現testは採用合格ではない。製品コード・依存・workflow変更なし。account / folder / UIDVALIDITY契約、認証・選択、合法unsolicited配送、複数FETCH応答間の重複・別originなどの網羅、実サーバ・3OS、全接続合計の厳密な資源制限は未達。本番採用保留・Phase 00未完了。

### 上限付きframingとTLS受信の接続

- test限定BoundedReceiverはstreamとframing stateを所有し、1 KiB固定read bufferから入力をenqueueする。共通next_responseで保持queueを処理し、未完かつqueue処理後のみ次のreadへ進む。正常時は応答bytesとreceiver全体を返すため、同時到着した後続応答を保持したまま次のreceiveができる。エラー時はreceiverを返さずdropして接続を破棄し、危険な再同期・skip_messageはしない。
- 各stepをabsolute deadline・取消futureとselectし、ready取消を期限切れより優先する。期限切れはreadがreadyでも先に判定できる形で、read後やInterruptedではyieldする。readの途中中断はTokioのcancel-safe readを使用。内部io errorはErrorKindで区別し、メールを含みうるerror文字列をDebugへ出さない。今回は通常のTLS EOFのみ注入しており、他のI/O errorやInterrupted連続の統合試験は未実施。
- 新規2 testsの計7ケースは、信頼した合成localhost証明書と通常のhostname検証でloopback implicit TLSを使う。正常時はSOURCEを含むFETCH応答とtagged OKを2回のreceiveで完全一致確認。異常系は50 MiB+1宣言と本文1 byte、129 bytesの改行なし入力（応答上限128）、decode不正、途中literalのclose_notify付きEOF、deadline、cancel。型付き原因をassertし、全ケースでpeer側の接続終了と後続command 0 bytesを確認する。TLS writeの一括送信はtransport readのchunk一致を保証しないが、分割に依存しないframingは既存の1 / 17 / 一括入力試験で検証済み。
- 過大literalではheaderのみ、応答全体超過では上限128 bytes、decode不正ではその応答、途中EOF / deadline / cancelでは処理済みのheader + partial本文をprefixとして回収。Debugは原因と長さだけ。これはIMAP wire prefixであり完全MIMEでも完全取得cacheでもない。framingの未処理queueやTLS内部、wrapper future自体のdrop / abort時のbytesは回収を保証しない。既存async-imapの途中literal回収blockerを修正したわけでもない。
- Linux arm64でunit5 + IMAP33 + MIME42 = 80 tests成功。異常系強化後もIMAP33 tests、対象clippy `-D warnings` / format / diff成功。既存probeの4 testsも維持。製品コード・依存・workflow変更なし。FETCH発行・認証・UID / 最終tagの照合・account / folder / UIDVALIDITY所属はこのreceiverへ未接続。3OS・実サーバ・厳密なメモリ量・全接続合計の資源制限も未検証。受信層の限定PoCであり、本番採用やPhase 00完了ではない。

### 既存Fragmentizerによる同時到着と累積応答上限

- [公式Fragmentizer資料](https://docs.rs/imap-codec/2.0.0-alpha.7/imap_codec/fragmentizer/index.html)と固定2.0.0-alpha.7の配布sourceを確認し、別名imap-codec-framingとしてoptional / imap-poc限定で追加。default-features=false、MIT OR Apache-2.0、Rust 1.85+。1.0.0の比較試験は維持し、既存async-imapのtransportを差し替えていない。プレリリース依存を本番採用する判断はしていない。
- 新規4 testsのtest限定probeはFragmentizer::newで応答全体の保持bytes上限を指定し、LineのLiteralAnnouncementでliteral単体上限と宣言終了offset + lengthの累積上限を検査する。offsetのchecked conversionとchecked_addを使い、overflowも拒否。最大1 KiBずつenqueueし、次を投入する前にprogressを使い切る。enqueue_bytesの未処理queueにはライブラリのサイズ制限がないため、この投入制限を省略してはならない。
- 1 / 17 / 一括入力すべてで、50 MiB+1 / u32::MAX宣言と本文1 byteが同時到着しても、本文をmessage bufferへ移す前にLiteralTooLargeを返し、保持message bytesはheaderだけとなる。50 MiB-1 / 50 MiBは宣言と本文1 byteだけの未完状態を確認し、実本文の境界は小さい32-byte上限に対して0 / 31 / 32 / 33 bytesで検証。50 MiBの完全応答をこのframing試験で処理したわけではない。試験のresponse上限に用いたraw上限 + 4096は評価用であり、製品protocol overheadの決定ではない。
- SOURCE中のprotocol風bytesを保持し後続tagged OKと正確に分離。複数literalの応答全体は設定上限を応答長-1 / ちょうど / +1として各分割で拒否 / 成功を検証。長大な改行なし入力もmessage bytesが上限128を超えず拒否。不正宣言はdecode失敗、途中literalは完成応答なし。独自のwire parserやskip_messageによる再同期は追加していない。
- 保証範囲は保持データ長と制限付きqueue投入。Vec / VecDequeの余剰capacity、decode内部allocation、返却応答コピー、全接続合計、CPU / RSSの厳密上限は測定していない。probeはテスト結果をまとめて返すだけで、EOF分類・deadline / cancel・エラー後の接続破棄・UID / tagged statusのsession判定を提供しない。エラー後にこのprobeを再利用して安全だとは扱わない。TLS付きtransportとの統合は次の未達条件。
- Linux arm64でIMAP31 tests、対象clippy `-D warnings` / format / diff成功。初回compileのoffset型不一致は修正。両codecがdefault依存graphから除外されることを確認。MIME単独・unit・3OS・実サーバは今回未検証、既存full IMAP stepで実行するためworkflow変更なし。制限付きframingの見通しは得たが、候補採用・Phase 00完了ではない。

### 代替imap-codecの宣言長通知API評価

- [公式Decoder資料](https://docs.rs/imap-codec/1.0.0/imap_codec/decode/index.html)と[ResponseDecodeError](https://docs.rs/imap-codec/1.0.0/imap_codec/decode/enum.ResponseDecodeError.html)、固定1.0.0配布sourceのcodec/decode.rs・core.rsを確認。MIT OR Apache-2.0。optional依存としてimap-pocのみへ追加し、既定のnumber補正・missing text補正を有効にしないためdefault-features=falseとした。async-imapの依存差替えやforkは行っていない。
- 新規4 testsを既存IMAP targetへ接続。literal headerの0 / raw 50 MiB-1 / 50 MiB / 50 MiB+1 / u32::MAXを64 bytes未満の入力だけで解析するとLiteralFoundが正確なu32長を返す。宣言途中の全prefixはIncomplete、負数・u32 overflow・不正文字列はFailed。本文用bufferを確保していない試験であり、parser全体のallocation計測やCPU制限の証明ではない。
- SOURCE全bytesを含む完全FETCHはUID 8・BODY[]・originなしで解析でき、直後のtagged OK / NO / BADはremainderに残り、次のdecodeでtag A0002と元statusを保持する。応答に似た本文bytesをprotocolとして分割しない。これはcodecの出力契約で、最終OK待ちを行うsession adapterではない。
- 重要制約: core.rsのliteral通知は宣言後のremainingが空の場合だけ。50 MiB+1のheaderだけならLiteralFoundだが、本文1 byteを追加するとIncompleteとなることを再現した。任意transport chunkのままdecodeして通知時だけ上限を検査する実装は不可。宣言境界を安全に扱う既存framing実装、複数literalを含む累積buffer上限、header上限、deadline / cancel、本文保持、TLS / session整合性の検証が必要。現段階で独自wire parserや「1 byteずつ再解析」で解決したとは扱わない。
- Linux arm64でIMAP27 tests、対象clippy `-D warnings` / format / diff成功。imap-poc単独8 testsも成功。初回linkerのsignal 9は-j 1再実行で解消（原因未確定）。cargo treeでdefault依存graphからcodecが除外されることを確認。MIME単独・unit・3OSは今回未再実行。既存full IMAP stepが新testsも実行するためworkflow変更なし。採用未確定、既存候補のblockerも未解消。

### literal宣言だけで製品上限を超えるallocation

- async-imap 0.12.0配布sourceのImapStream::decodeはimap-protoのNeeded::Sizeからdecode_needsを設定し、do_poll_nextは次のtransport poll_readより先にBuffer::ensure_capacityを呼ぶ。Buffer::growはBytesMut::resizeで領域を初期化する。固定MAX_CAPACITYは512 MiBであり、無制限ではないが、製品raw上限50 MiBより大きい。bufferとdecode_needsは非公開、Client / Sessionの公開APIに上限変更設定は見当たらない。
- 新規header-only transportはFETCHのliteral宣言までしか返さず、次のreadではReadBuf::remainingを記録して明示的な合成budget errorを返す。64-byte宣言は既存buffer内で処理される一方、50 MiB+1宣言は本文0 bytesのまま宣言長以上の初期化済み領域が次のreadへ渡される。これは容量予約の推測やRSS測定ではなく、transportが利用できる初期化済み領域の直接観測。transport側のbyte budgetやdeadlineではこの先行allocationを防げない。
- 別testで512 MiB+1宣言を渡し、候補自身のincoming data too largeとread 1回だけを確認。512 MiB超のbufferを実際に確保する試験ではない。固定上限は1応答bufferの上限であり、返却ResponseData・本文コピー・同時接続を含むプロセス全体のメモリ制限ではない。
- Linux arm64でIMAP23 tests、同targetのclippy `-D warnings` / format / diff成功。初回clippyのlet_and_return警告は修正。既存のFETCH最終status欠陥再現2件に加え、今回のallocation制限再現も採用合格に数えない。MIME単独・unit・3OSは今回未実行。製品コード・依存・workflow変更なし。
- 判断: 現候補をそのまま本番採用しない。候補内部でgrowより前に製品上限とprotocol overheadを明示的に検証できる変更、または上限付きstreamingを提供する別parser候補の評価が必要。未信頼応答の独自wire parserやtransport wrapperによる見かけ上の修正は採用しない。依存差替え・forkは未実施であり、このblockerを解消したとは扱わない。

### TLS上の最終応答異常と未完literal

- 合成implicit TLS peerにNO / BAD / 別tagのOK / 完了応答前EOF / literal途中EOFを追加し、新規1 testで5ケースを実行。既存の正常・cancel・deadline試験も維持するため、fixtureの曖昧なbool組合せを明示的な終了シナリオへ置換した。証明書・hostname検証は有効のまま。
- checked_fetchはNO / BADをRejected、別tagをUnexpectedResponse、完了応答前EOFをMissingCompletion、literal途中EOFをIoとして返す。owned wrapperは全失敗でsessionを破棄し、peerが後続command 0 bytesと接続終了を確認。完全literalが返された4ケースはSOURCE全bytesをprovisionalとして保持するが成功本文へ昇格しない。途中literalはcandidate内部bufferから回収できずNoneとなる。
- EOFの2ケースはTLS close_notifyと書込側shutdownで注入し、TLS層の正常終了をIMAP command成功と混同しないことを確認する。TLS close_notifyなしの切断はこの追加試験の対象外。正常時の再利用や中断時の終了は直前のPoCで検証済み。
- Linux arm64でIMAP21 tests、同targetのclippy `-D warnings` / format / diff成功。MIME単独・unit testsは今回未再実行。既存の欠陥再現2件は採用gate合格ではない。製品コード・依存・workflow変更なし。実サーバ・3OS・STARTTLS後のFETCH・account scope・allocation上限・途中literal回収などの未達と本番採用blockerは維持する。

### 実TCP / 検証済みTLSでのFETCH中断PoC

- test限定のchecked_fetch / owned_checked_fetchをストリーム型で一般化。async-imap 0.12.0の公開Session APIと同じAsyncRead + AsyncWrite + Unpin + Debug + Send boundを使用し、既存DuplexStream試験に加えてloopback TCP上のrustls streamへ接続した。証明書は既存の合成localhost証明書設定を再利用し、hostname / 証明書検証を無効化していない。資格情報・本文は合成値のみ。
- 新規2 testsは正常1ケースと中断4ケースを実行。正常時は一致tagged OKの検証後にSOURCE全bytesを返し、MIME解析と同じsessionでのNOOPに成功する。NOOPはFETCH成功の代用ではなく、返却sessionの再利用確認。本文途中 / 完全literal後の完了待ちそれぞれをcancel / deadlineで中断するとsessionを返さず破棄し、Cancelled / TimedOutと完全literalだけのprovisional回収を確認。peerは後続command 0 bytesとEOFまたはTLS close_notifyなしのUnexpectedEofを観測する。graceful TLS shutdownを保証する試験ではない。
- Linux arm64でunit5 + IMAP20 + MIME42 = 67 tests、対象clippy `-D warnings` / format / diff成功。初回はSend bound不足でcompileに失敗し、公開Session APIのboundに合わせて修正。既存の欠陥再現2件は採用gate合格に数えない。
- TLS終了の未検証範囲はこのimplicit TLS合成peerに限って縮小した。mailbox選択状態・Seen不変、実サーバ、STARTTLS後のFETCH中断、3OS、task abort / wrapper future自体のdrop時の回収、途中literal回収、読込allocation上限、unsolicited配送、account / folder / UIDVALIDITY所属は未達。製品コード・依存・workflow変更なし、本番採用blockerは維持する。

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
- 文字コード診断の限界を追加fixtureで確認。正当にUTF-8表現されたU+FFFDのほか、Shift_JIS / EUC-JPの不正lead / trail、ISO-2022-JPの未完了文字sequenceをASCII suffix前に注入した。mail-parser 0.11.9は各不正sequenceをU+FFFDに変換し後続ASCIIを保持する一方、`replacement_character_present=true`、`unrecognized_text_charset=false`、`is_encoding_problem=false`を返す。UTF-16LE / UTF-16BEでは不正なodd trailing byteを黙って落として本文を切り詰め、replacement診断はfalseのまま。また、両endianのunpaired surrogateをU+FFFDにするがencoding problemにはしない。よって診断とparser flagは損失を見逃すだけでなく、不正変換の位置や原byteを表示文字列から示さない。原EML自体は保持される。`mime_candidate`はLinuxで43 tests成功。製品コード・依存・workflow変更なし。これらは固定parserの少数合成sequenceであり、全charset損失・解析中資源制限・3OS runtimeを証明しない。
- quoted-printableの不正escapeを検証。`=GG`は本文にそのまま残る一方、末尾の単独`=`は本文から落ちる。両ケースとも`is_encoding_problem=false`、MIME診断はdefaultのままで、raw sourceだけが原bytesを保持する。したがって転送encoding flagは全ての不正escape検出を保証せず、表示本文が原文を忠実に含むとも限らない。新規1 test追加後の`mime_candidate`はLinuxで44 tests成功。製品コード・依存・workflow変更なし。このprobeは2種類のquoted-printable malformed sequenceに限られ、他の転送encoding異常系や3OS runtimeを証明しない。
- quoted-printable soft breakの境界を追加確認。正規の`=\r\n`は次行へ連結される。固定parserは裸LFのみ、および`=`の後にspace / tabを置いてからCRLFを続ける非正規入力も同じように改行と直前空白を消して本文を連結し、`is_encoding_problem=false` / MIME診断defaultを返す。raw sourceは全入力bytesを保持。新規1 test（4合成形）を含めLinuxで`mime_candidate` 45 tests成功。製品コード・依存・workflow変更なし。裸LFと空白を挟む形は規格準拠の肯定例ではなく、候補のtolerant behavior確認に限定。
- quoted-printable不正escapeの回復境界を追加確認。末尾の不完全な`=A`は`=A`ごと本文から脱落し、`=\rX`はCRを失って`=X`として本文に残る。`=GG`はそのまま残り、単独末尾`=`は脱落する既知結果と合わせ、いずれも`is_encoding_problem=false` / MIME診断defaultで、raw sourceのみ全入力bytesを保持。既存testへfixtureを追加し、Linuxで`mime_candidate` 45 tests成功。少数の合成形であり、quoted-printable全異常系や3OS runtimeを証明しない。
- quoted-printable正常hexとhard lineの境界を検証。小文字`=3d`・大文字`=3D`はいずれも`=`へdecodeされ、通常のCRLFは本文に保持される一方、hard line末尾のspace / tabは本文から除去される。これらも`is_encoding_problem=false` / MIME診断defaultで、raw sourceは元bytesを保持。新規1 test（4合成形）後、Linuxで`mime_candidate` 46 tests成功。末尾空白を失う可能性のある候補parser挙動の再現に限られ、他の改行形式や3OS runtimeは未検証。
- quoted-printableの行長・bare CRを確認。76文字と77文字のASCII bodyはいずれも長さ検証やencoding診断なしにそのまま受理される。本文中の単独CRは本文から除去され、隣接文字が連結する。3合成形すべてで`is_encoding_problem=false` / MIME診断default、raw sourceは元bytesを保持。新規1 test追加後、Linuxで`mime_candidate` 47 tests成功。短い合成行に限り、decoderがRFC行長制約を検証する保証や全改行形 / 3OS runtimeを示さない。
- quoted-printableのbody終端空白を確認。`=20` / `=09`のencoded space / tabと、EOF直前のliteral space / tabは、いずれも末尾改行がない場合に本文へ保持される。4形すべて`is_encoding_problem=false` / MIME診断defaultで、raw sourceは元bytesを保持。新規1 test追加後、Linuxで`mime_candidate` 48 tests成功。改行終端lineの直前空白が削られる既知挙動とは区別されるが、全改行形式や3OS runtimeは未検証。
- quoted-printable本文の混在hard line endingを確認。最初のCRLF後に続くbare LFもCRLFとして本文へ出力され、入力のLF表現を保たずdecoder内で改行styleが再利用される。`is_encoding_problem=false` / MIME診断default、raw sourceは元bytesを保持。新規1 test追加後、Linuxで`mime_candidate` 49 tests成功。混在する合成2改行に限る観測で、全改行列や3OS runtimeを証明しない。
- quoted-printable soft break後の改行styleも確認。先行する裸LF soft breakは本文から除去され、以降のhard CRLFはCRLFとして保持される。soft breakに使われたLFをhard line styleとして扱わない。`is_encoding_problem=false` / MIME診断default、raw sourceは元bytesを保持。新規1 test追加後、Linuxで`mime_candidate` 50 tests成功。単一の合成混在列に限る観測で、全改行列や3OS runtimeを証明しない。
- quoted-printable multipart境界の回帰fixtureで、part本文`before\r\n`は`before`として復元される一方、`before=\r\n`のsoft break直後にboundaryが来ると本文は`befo`となり末尾`re`の2 bytesが欠落することを確認。後続part自体は保持されるが、`is_encoding_problem=false` / MIME診断defaultのままでraw sourceのみ全bytesを保持する。mail-parser 0.11.9候補でのsilent body truncationであり、候補parserを採用する上で本文忠実性のblockerとして扱う。合成fixture 2種のみで、影響範囲・修正版・他OSは未確認。
- multipart boundary直前のsoft breakについて、1〜4文字の同一本文長をprofile別に試験。debugでは1文字だけdecoder内overflow panic、2〜4文字は本文がそれぞれ空 / 1文字 / 2文字へ短縮。isolated release targetではpanicせず、1文字本文は末尾にboundaryの`-`が混入し、2〜4文字は同じく2文字短縮。全て診断defaultでraw source保持。固定依存内部挙動がprofileによりpanic / silent corruptionへ分岐することを確認し、候補parser採用blockerとして扱う。`mime_candidate`はLinux debug 53 tests成功、profile別matrixもpass。限定的な合成長さ・Linuxのみで、production feature接続や他OSは未確認。
- 同じ`before=\r\n` part末尾soft breakでclosing delimiter `--boundary--`を使っても本文は`befo`となり、末尾`re` 2 bytesが脱落。opening delimiter後に続くpartの有無では解消しない。`is_encoding_problem=false` / MIME診断default、raw sourceは完全保持。追加のclosing-boundary fixture後、Linux debug `mime_candidate` 54 tests成功、release profileのquoted-printable該当11 tests成功。少数の合成形であり、すべてのboundary表記・修正版・他OSは未検証。
- soft break後に実データ行が続く場合の対照fixtureを追加。`before=\r\ncontinued\r\n--boundary`は本文`beforecontinued`、後続partも独立して保持され、silent lossを再現しない。直前boundaryケースとの違いはsoft breakの直後にdelimiterが来るか、本文データが続くか。診断defaultでraw source保持。追加1 test後、Linux debug `mime_candidate` 55 tests成功。該当する合成CRLF形のみ確認し、他改行・boundary形式や3OSを証明しない。
- すべてLFのmultipart delimiterと`before=\n--boundary`を使うと本文は`befor`となり、末尾`e` 1 byteが欠落する。CRLF delimiter時は末尾`re` 2 bytes欠落であるため、区切り改行形式によって損失長が異なる。flagなし・MIME診断default・raw source保持。新規LF境界fixture追加後、Linux debug `mime_candidate` 56 tests成功。2種類の合成delimiter形に限る。
- CRLF boundary直前のsoft breakで、`=`の後にspace / tabを含めても本文は`befo`となり、CRLFのみの既知caseと同じ末尾2 bytesが失われる。後続partとraw sourceは保たれ、すべて`is_encoding_problem=false` / MIME診断default。追加1 test（3入力形）後、Linux debug `mime_candidate` 57 tests成功。限定fixtureであり、他whitespace・line endingや3OSは未確認。
- bare LF delimiterの場合も、`=\n`、`= \n`、`=\t\n`の3形はいずれも本文を`befor`へ切り詰め、末尾`e` 1 byteを失う。後続part・raw sourceは保持し、全形でencoding problem flag / MIME診断なし。新規1 test（3形）後、Linux debug `mime_candidate` 59 tests成功。合成LF境界形のみであり、他whitespaceや3OSは未検証。
- multipart delimiterとquoted-printable soft breakの改行形式が混在する6形を追加確認。本文の損失量はdelimiter側ではなくsoft break側のLF / CRLFに従い、LFでは末尾1 byte、CRLFでは2 bytesが失われる。`=`後のspace / tabでも同じ結果。後続part・raw sourceは保持し、encoding problem flag / MIME診断はなし。追加1 test（6形）後、Linux debug `mime_candidate` 60 tests成功。これは限定した合成改行混在形であり、全改行列や3OS runtimeを網羅しない。
- LFのclosing boundary直前でも、`=\n`、`= \n`、`=\t\n`の全3形で本文末尾1 byteが無診断で失われ、本文は`befor`となる。raw sourceは保持され、encoding problem flag / MIME診断はなし。追加1 test（3形）後、Linux debug `mime_candidate` 61 tests成功。closing boundaryの限定した合成LF形であり、3OS runtimeは未検証。
- closing delimiterが終端改行なしでEOFに達する場合も本文損失は変わらない。CRLF soft breakの3形（通常 / space / tab）は末尾2 bytes、LF soft breakの3形は末尾1 byteを無診断で失う。raw sourceは保持され、encoding problem flag / MIME診断なし。追加1 test（6形）後、Linux debug `mime_candidate` 62 tests成功。限定した合成EOF形であり、3OS runtimeは未検証。
- LF soft breakの直後にboundaryが来るケースでは、本文長1〜4文字の全てで本文を1文字短縮する。`=\n`、`= \n`、`=\t\n`の3形ともdebug buildでpanicせず、後続partとraw sourceを保持する一方、encoding problem flag / MIME診断はなし。isolated release profileでも同じ出力を確認。追加1 test（12形）後、debug `mime_candidate` 63 tests成功、release profile対象test成功。比較対象はLF soft breakの合成fixtureに限られ、3OS runtimeや他の文字長は未検証。
- CRLF soft breakの後にspace / tabを含む短い本文もdebug buildで破損する。`=\r\n`、`= \r\n`、`=\t\r\n`の3形すべてで、本文長1はdecoder内overflow panic、長さ2〜4は2文字短縮。非panic形では後続partとraw sourceは保持されるが、encoding problem flag / MIME診断なし。追加1 test（12形）後、debug `mime_candidate` 64 tests成功。isolated release profile検証は、test target内のTokio / mail-parserの同一version重複による型不一致でコンパイルできず、未確認。限定した合成長さ・whitespace形で、他OS runtimeは未検証。
- UTF-8の複数byte文字を境界直前に置くと、ASCIIの同byte長試験とは異なり、CRLFでは`é`が空文字、`日` / `😀`がU+FFFD、LFでは全1文字例がU+FFFDになる。2文字例も末尾文字の一部を失い、CRLFの`日é`は`日`、LFは`日�`となるなど入力文字・改行形式に依存して破損する。`=`後space / tabも各CRLF / LF群と同じ結果。後続partとraw sourceは保持し、encoding problem flag / 未認識charset診断なし。出力にU+FFFDがあるcaseではreplacement presence診断はtrueだが、失われた原byteや位置を示さない。追加1 test（30形）後、Linux debug `mime_candidate` 65 tests成功。合成UTF-8本文と限定soft break形であり、3OS runtimeは未検証。
- 同じ4本文をUTF-8 octetごとのquoted-printable `=XX`表記（`=C3=A9`、`=E6=97=A5`、`=F0=9F=98=80`、連結形）に変えても、各CRLF / LF soft breakおよび後続space / tabに対するdecoded本文はraw UTF-8入力と同じ破損結果。元のQ-P sourceは保持されるが、encoding problem flag / 未認識charset診断はなく、U+FFFD presence診断は置換文字が生じた場合だけtrue。追加1 test（24形）後、Linux debug `mime_candidate` 66 tests成功。限定したUTF-8列・境界合成形であり、全charset / profile / OSを網羅しない。
- UTF-8の`é`を構成するquoted-printable octet `=C3=A9`を`=C3=` + soft break + `=A9tail`として分割し、6形（CRLF / LF、空白なし / space / tab）を試験。全形で本文`étail`と後続partを正しく保持し、raw source一致、encoding problem / U+FFFD診断なし。これはsoft break直後がboundaryで終わる場合のsilent truncationとは異なる対照結果。追加1 test（6形）後、Linux debug `mime_candidate` 67 tests成功。限定したUTF-8 octet分割形であり、全encoding列や3OS runtimeを証明しない。
- `=C3=A9`列全体を7 byte位置でsoft break分割。octet境界（split 0 / 3 / 6）の6改行形は`étail`と後続partを保持。`=C3=A9` escape内部のsplit 1 / 2 / 4 / 5は全CRLF / LF・space / tab形でMIME adapterがIncompleteを返し、部分本文を成功扱いにしない。panicはなく、error文字列に本文suffixは含まれない。新規1 test（42形）後、Linux debug `mime_candidate` 68 tests成功。合成UTF-8列と指定したsplitだけの結果であり、全encoding列や3OS runtimeは未検証。
- 3-byte UTF-8文字`日`の`=E6=97=A5`も全10 byte位置×6 soft break形を確認。octet token境界のsplit 0 / 3 / 6 / 9は`日tail`と後続partを保持し、escape内部の残り位置は全てIncomplete。soft breakのCRLF / LF・space / tabによる差はなくpanicなし。追加1 test（60形）後、Linux debug `mime_candidate` 69 tests成功。1つの3-byte文字に限定した確認であり、全入力や3OS runtimeは未検証。
- 4-byte UTF-8文字`😀`の`=F0=9F=98=80`も全13 byte位置×6 soft break形を確認。octet token境界（split 0 / 3 / 6 / 9 / 12）は`😀tail`と後続partを保持し、escape内部位置は全てIncomplete。CRLF / LF・space / tabの差はなくpanicなし。追加1 test（78形）後、Linux debug `mime_candidate` 70 tests成功。1つの4-byte文字に限定した確認であり、全入力や3OS runtimeは未検証。
- 隣接する`é日`のoctet列`=C3=A9=E6=97=A5`も全19 byte位置×6 soft break形を比較。octet token境界（split 0 / 3 / 6 / 9 / 12 / 15 / 18）は`é日tail`を保持し、escape内部splitはIncomplete。CRLF / LF・space / tabの差はなくpanicなし。追加1 test（114形）後、Linux debug `mime_candidate` 71 tests成功。2文字の固定列に限定し、一般化や3OS runtimeの証明ではない。
- UTF-8 `é`の`=C3`と`=A9tail`の間に同形式のsoft breakを2回 / 3回連続で挿入する12形を確認。CRLF / LFおよびspace / tabの全形で`étail`・後続part・raw sourceを保持し、診断default / encoding problemなし。panicなし。追加1 test（12形）後、Linux debug `mime_candidate` 72 tests成功。限定した2 / 3回の連続soft break列であり、資源上限や任意長反復は未検証。
- multipart boundary直前のhard line空白回復を比較。literal space / tabはCRLFとboundaryの前で除去されるが、encoded `=20` / `=09`はそれぞれspace / tabとして本文に残る。4合成形全てで後続partとraw sourceを保持し、encoding problem flag / MIME診断なし。新規1 test（4形）追加後、Linux debug `mime_candidate` 58 tests成功。境界直前の対象空白表現に限る観測で、他whitespaceやline endingを網羅しない。
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
