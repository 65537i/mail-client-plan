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

- malformed/large MIMEはこのcrateの責務外で、MIME候補の別PoCを行う。未対応IMAP extensionはcapabilityを確認して基本commandへfallbackし、存在しないextensionを仮定しない。
- SMTP final response後の永続化kill / 接続切断によるOutboxのunknown分類、複数RCPTの個別失敗UXを別PoCで確認する。lost / truncated responseで候補がエラーを返すことは確認したが、SMTP `Error`だけで再送可否を決めず、DATA送出境界を記録するoutbox state machineが必要。
- SMTP TLSの接続・認証・固定合成本文送信はPoCで確認したが、OAuth2 mechanism、MIME生成、production adapterの入力検証 / OS trust store / timeout・取消方針は未実装。固定版lettreはTLS handshake errorをconnection errorに包むため、`is_tls()`だけで認証・TLSエラー分類を決めない。TLS検証失敗時のsource chainを評価する必要がある。
- 3OS native compile / runtimeをCIで確認し、license、release/issue healthを再確認してから採用確定ADRへ変更する。
- mailbox name、sequence set、FETCH query、custom command等に任意文字列を連結するAPI面がある。domain adapterで型・validation・constant queryを強制し、UIへ汎用command実行面を公開しない。

## 再評価条件

IDLE cancel後にcommand streamが不整合となる、TLS/STARTTLS境界で安全な認証前提を保てない、必要なUID semanticsを取得できない、または3OSでbuild/runtimeが維持できない場合は候補を棄却し、別clientまたはより低レベルの候補を比較する。
