# 公式資料と技術判断

確認日: 2026-10-20。以下は根拠となる一次資料。本文の性能値、Phase構成、キャッシュ量、製品OS範囲は本計画の提案であり、公式仕様が保証する値ではない。

| 領域 | 資料 | この計画での扱い |
|---|---|---|
| Tauri capability | https://v2.tauri.app/security/capabilities/ | window/webview scope、権限の合算、custom commandの明示制限 |
| Tauri CSP | https://v2.tauri.app/reference/config/ | 固定版のconfig schemaで検証。本文専用ポリシーも必要 |
| IMAP | https://www.rfc-editor.org/rfc/rfc9051 | UID/UIDVALIDITY、サーバ状態を意識した同期。rev1互換も維持 |
| メールTLS | https://www.rfc-editor.org/rfc/rfc8314 | TLS必須、平文fallback拒否 |
| OAuth native | https://www.rfc-editor.org/rfc/rfc8252 | 外部ブラウザ、公開クライアント、PKCE、redirect保護 |
| Gmail XOAUTH2 | https://developers.google.com/workspace/gmail/imap/xoauth2-protocol | IMAP/SMTP scope、provider認証設定 |
| Microsoft OAuth | https://learn.microsoft.com/en-us/exchange/client-developer/legacy-protocols/how-to-authenticate-an-imap-pop-smtp-application-by-using-oauth | 委任scope、protocol audience、tenant設定 |
| SQLite FTS5 | https://www.sqlite.org/fts5.html | trigram、短いqueryの制限、外部content整合性、削除残存 |
| Tauri tests | https://v2.tauri.app/develop/tests/ | ブラウザと実Tauri試験を分離 |
| WebDriver | https://v2.tauri.app/develop/tests/webdriver/ | WebdriverIO serviceの組み込み方式を3OSでPoC |
| 従来driver | https://v2.tauri.app/develop/tests/webdriver/manual-setup/ | 直接tauri-driverはmacOS対応と混同しない |
| CI配布 | https://v2.tauri.app/distribute/pipelines/github/ | native build、固定版action、署名済み配布 |
| Windows署名 | https://v2.tauri.app/distribute/sign/windows/ | 配布署名、timestamp、秘密管理 |
| macOS署名 | https://v2.tauri.app/distribute/sign/macos/ | 署名・公証とupdater鍵を区別 |
| Copilot指示 | https://docs.github.com/en/copilot/concepts/prompting-and-context/custom-instructions | 短い常設指示と詳細なPhase資料を分離 |

## Phase 00で閉じるADR

- ADR-001: OS最低版・CPU・runner・WebView・installer形式。
- ADR-002: IMAP/SMTP/MIME/TLS依存、必要feature、拡張非対応時のfallback。
- ADR-003: 本文sandbox、sanitizer、CSP、CID、リンク操作と3OS攻撃試験。
- ADR-004: SecretStore、Linux service不能時、refresh token置換。
- ADR-005: SQLite/blob整合性、migration/backup、平文保存の許容範囲。
- ADR-006: 日本語trigramの精度・容量・短いquery・normalization。
- ADR-007: 3OS WebDriver、テスト専用feature、本番からの除去証明。
- ADR-008: SMTP不明状態、Sent保存方針、provider別自動保存。

各ADRは背景、選択肢、実験条件、結果、採用理由、制限、再評価条件を記載する。未検証の依存API・plugin permission名・GitHub Actions版を「動く設定」として生成しない。
