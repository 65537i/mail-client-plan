# Phase 06: Google / Microsoft OAuth2

この指示は`prompts/00-master.md`と設計書を前提とする。現在のリポジトリを調べ、既存実装を活かして進めてください。

## 前提

Phase 05完了を基本とする。閲覧MVPにOAuthが必要なら認証部分だけPhase 02前へ移す。

## 受け入れ基準

`docs/02-acceptance-tests.md`のAC-16、AC-17。関連する既存ACを回帰させない。

## 順番に実装する縦切り機能

### 06A: 認証基盤

実装: AuthProvider trait、Authorization Code+PKCE S256、外部ブラウザ、state、loopback一回限りcallbackを実装する。client secretは持たない。

検証: fake OAuth serverで不一致、期限切れ、callback再利用、取消、port競合を再現する。

### 06B: token lifecycle

実装: Rust内access token、SecretStoreのrefresh token、account単位single-flight、rotation置換、invalid_grant再認証を実装する。

検証: 同時IMAP/SMTP更新は1回、SecretStore書込失敗で秘密を平文退避しない。ログ/DB/browser storageを検査する。

### 06C: provider設定と実機確認

実装: GoogleとMicrosoftを別profileにし、scope/audience/tenant/account type/XOAUTH2/SMTP AUTH可否を明示する。登録手順、審査・consent・取消手順をdocsへ追加する。

検証: fake試験の後、専用accountによる内部実機試験を別gateとして記録する。外部準備不足をmock成功で完了扱いにしない。

## 制約

MFA解除や基本認証の強制有効化を要求しない。公開審査・tenant policy・署名鍵等は具体的な未達条件として報告する。

## この依頼の進め方と提出物

最初に未完了の縦切り機能を1つ選び、変更範囲と試験を短く示して実装する。API・permission・依存版は採用ADRと公式資料で確認する。各縦切り機能を完了してから次へ進む。

完了時は変更差分、AC ID、実行コマンドと結果、3OS CI状態、異常系の証拠、未実施チェック、既知制限を報告し、`docs/status.md`を更新する。Phase全体のgateが未達なら完了と宣言しない。外部資格情報等が必要でも、安全に実装・ローカル検証できる範囲を先に完成させ、必要な外部準備を具体的に列挙する。
