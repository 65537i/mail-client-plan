# Phase 08: 3OS安定化・署名・配布

この指示は`prompts/00-master.md`と設計書を前提とする。現在のリポジトリを調べ、既存実装を活かして進めてください。

## 前提

Phase 00〜07の全gate完了。外部署名/OAuth公開準備の状況を明示。

## 受け入れ基準

`docs/02-acceptance-tests.md`のAC-21、AC-22、AC-23、およびAC-00〜20回帰。関連する既存ACを回帰させない。

## 順番に実装する縦切り機能

### 08A: native品質

実装: 全対象OS/archで実WebView、SecretStore、IME、a11y、休止復帰、長時間同期、性能、悪意HTMLの回帰試験を実施する。

検証: docs/statusにOS/WebView/commit/CI runと手動証跡を残し、未実施を合格にしない。

### 08B: release pipeline

実装: protected environment、固定SHA actions、SBOM、hash、OS署名/公証、更新署名、debug/WebDriver除去検査を実装する。

検証: 本番バイナリの待受と依存を確認し、改変artifactを拒否する。署名鍵不足ならreview可能なpipelineまで作りgateを未達と記録する。

### 08C: install/update/recovery

実装: clean install、旧版upgrade、更新切断、migration失敗、旧版起動拒否、backup復元、uninstallを各OSで確認し、利用者向け制限・復旧・プライバシー説明を作る。

検証: リリースチェックリストとdraft release内容を作成する。公開は別途明示されたときのみ行う。

## 制約

既知のデータ喪失、秘密漏洩、無断再送があれば出荷しない。3OS build greenだけを安定版合格としない。

## この依頼の進め方と提出物

最初に未完了の縦切り機能を1つ選び、変更範囲と試験を短く示して実装する。API・permission・依存版は採用ADRと公式資料で確認する。各縦切り機能を完了してから次へ進む。

完了時は変更差分、AC ID、実行コマンドと結果、3OS CI状態、異常系の証拠、未実施チェック、既知制限を報告し、`docs/status.md`を更新する。Phase全体のgateが未達なら完了と宣言しない。外部資格情報等が必要でも、安全に実装・ローカル検証できる範囲を先に完成させ、必要な外部準備を具体的に列挙する。
