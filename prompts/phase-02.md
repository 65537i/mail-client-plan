# Phase 02: 複数IMAPアカウントの閲覧MVP

この指示は`prompts/00-master.md`と設計書を前提とする。現在のリポジトリを調べ、既存実装を活かして進めてください。

## 前提

Phase 01完了。TLS/SecretStore/HTML隔離PoCが成功。

## 受け入れ基準

`docs/02-acceptance-tests.md`のAC-03、AC-04、AC-05、AC-06。関連する既存ACを回帰させない。

## 順番に実装する縦切り機能

### 02A: アカウント接続

実装: 登録/接続テスト/解除、暗黙TLSと必須STARTTLS、SecretStore保存を実装する。接続エラーを分類し、秘密をDTO/logへ返さない。

検証: TLS付きfixture serverへ2アカウント接続できる。証明書不正とSTARTTLS剥奪で認証前に停止する。

### 02B: フォルダとメタデータ

実装: LIST/EXAMINE、UIDVALIDITYとUIDによる一覧、envelope/flags/BODYSTRUCTURE、最新200件と続きの取得を実装する。表示名とサーバ識別子を分ける。

検証: 同じUIDを持つ別フォルダ・別accountが混ざらない。非ASCII名、空フォルダ、UID欠番を試す。

### 02C: 本文と添付

実装: 選択時にBODY.PEEKでMIME取得、プレーン本文を既定表示。検証済みsanitizer+sandbox HTML、CID制限、添付保存、サイズ/ネスト上限を実装する。

検証: 閲覧でSeenが変わらない。悪意あるfixtureを3OS実WebViewで遮断し、添付パストラバーサルを拒否する。

## 制約

このPhaseは読み取り専用。STORE/MOVE/DELETE/SMTPを公開しない。Gmail/Microsoftのパスワード認証を前提にしない。

## この依頼の進め方と提出物

最初に未完了の縦切り機能を1つ選び、変更範囲と試験を短く示して実装する。API・permission・依存版は採用ADRと公式資料で確認する。各縦切り機能を完了してから次へ進む。

完了時は変更差分、AC ID、実行コマンドと結果、3OS CI状態、異常系の証拠、未実施チェック、既知制限を報告し、`docs/status.md`を更新する。Phase全体のgateが未達なら完了と宣言しない。外部資格情報等が必要でも、安全に実装・ローカル検証できる範囲を先に完成させ、必要な外部準備を具体的に列挙する。
