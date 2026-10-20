# ADR-004: SecretStoreとTLS拒否のPoC

- 状態: 暫定。TLS異常系、Linux Secret Service実保存成功と利用不能時の明示失敗を確認。lock・3OSは未確認
- 決定日: 2026-10-20

## 背景

AC-06は不正証明書、ホスト名不一致、STARTTLS拒否で認証情報を送らないこと、およびOS資格情報ストアが利用できない場合に平文保存しないことを求める。Phase 00のPoCでは実provider資格情報やメールサーバを使わない。

## 決定

- `keyring` 3.6.3をOS資格情報ストア候補として選び、Linuxは同期Secret Service、macOSはKeychain、WindowsはCredential Managerのnative backendを明示する。
- keyring依存と全PoC commandは`security-test` featureのときだけ有効化する。Linux backendは`sync-secret-service`のみとし、keyutilsとのcomboやmock backendへfallbackしない。
- Linux Secret Service通信は`crypto-rust`を明示し、OpenSSLのnative library要件を避ける。backendが無い・ロック・拒否の場合はエラーを返し、ファイル保存経路を実装しない。
- security-test専用IPCは固定service名と検証済みの合成test IDを使う。書き込み値はテスト用合成文字列に限り、通常buildにはcommand/permissionを含めない。
- TLS PoCはrustls 0.23.37とtokio-rustls 0.26.6を使い、テストごとに生成する自己署名localhost証明書をローカルloopbackだけで使う。既定の証明書検証を無効化しない。
- 認証相当の合成payloadはTLS handshakeが成功してからのみ書く。信頼されない証明書と信頼済み証明書のhostname mismatchの両方でhandshake失敗と、server側受信byte数0を確認する。
- 合成SMTP peerがSTARTTLSを拒否した場合、認証相当payloadを送らずに終了することもloopbackで確認する。

## 検証方法と現在の証拠

| 確認 | 結果 |
|---|---|
| TLS不正証明書 / hostname mismatch / STARTTLS拒否 | `src-tauri/tests/security/tls_auth_boundary.rs`の3ケースすべてでloopback peerの認証相当payload受信0を確認 |
| Linux Secret Service | GNOME Keyring daemonを一時起動したLinux WebView試験で合成secretの保存・読み出し・削除・削除後の未登録エラーを確認。daemon不在時の明示エラーも確認。filesystem監視は未確認 |
| CIでのOS store success gate | native workflowにLinux Secret ServiceのDBus service起動確認を追加し、Linux / macOS / Windowsで保存・読み出し・削除に失敗した場合はCIを失敗させる設定。actionlint 1.7.12でworkflow検査成功。GitHub Actions実行は未確認 |
| 通常buildへのtest依存 | `keyring`、TLS PoC依存、IPC commandは`security-test` featureに限定 |
| 平文fallback | 実装にファイルbackendを持たせず、OS store呼出し失敗は明示エラーとする |

## 未達・制限

- Linux成功系は一時展開したDebian GNOME Keyring daemonで確認。CI runnerの同等実行と、ロック状態・アクセス拒否・削除失敗の実証は未完了。
- macOS Keychain / Windows Credential Managerの保存・ロック・拒否・削除は各OS実機で未確認。
- CI runner上でkeyring success gateが通ることはまだ確認しておらず、runner実行が必要。
- SMTPテストは最小の合成STARTTLS peer/clientであり、実IMAP/SMTP adapterの統合検証ではない。将来のprotocol adapterでもTLS handshake完了前に認証情報を取得・送信しない契約テストが必要。
- Rustls local server testはTLS-before-authentication境界のPoCであり、将来のmail adapterの統合検証に置き換える必要がある。
- 無資格情報の利用者環境やロックされたOS storeでは保存を成功扱いせず、利用者に失敗を通知する。平文fallback・自動再試行は行わない。

## 再評価条件

いずれかのbackendが平文または不意な代替storeへfallbackする、証明書検証失敗前に認証相当payloadが届く、またはOS別のロック挙動が設計要件と異なる場合は候補採用を保留し、適合するbackendへ変更する。
