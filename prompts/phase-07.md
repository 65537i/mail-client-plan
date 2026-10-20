# Phase 07: 日本語全文検索・容量管理・復旧

この指示は`prompts/00-master.md`と設計書を前提とする。現在のリポジトリを調べ、既存実装を活かして進めてください。

## 前提

Phase 06完了。Phase 00のtrigram検証と保存前提を引き継ぐ。

## 受け入れ基準

`docs/02-acceptance-tests.md`のAC-18、AC-19、AC-20。関連する既存ACを回帰させない。

## 順番に実装する縦切り機能

### 07A: 索引とquery compiler

実装: 取得済みsubject/body/addressをversion付き正規化しsearch_documents+FTS5へtransaction同期する。構造化検索、scope強制、bind/escape、timeout、cancelを実装する。

検証: 日本語3文字以上、全半角、複合filter、FTSメタ文字入力を試す。1〜2文字はscope限定の上限付きfallbackで契約を明示する。

### 07B: 再索引と性能

実装: バックグラウンドbatch索引、進捗、再構築、破損検知、10万件benchmarkを実装する。

検証: 更新/削除/再起動で原本と一致する。未取得本文は検索対象外。p95とDB増加量を記録する。

### 07C: 容量と復旧

実装: LRU cache、quota、pin、孤立blob GC、consistent backup、restore、migration失敗UIを実装する。account解除時にFTS/blob/secretを除去する。

検証: disk full、backup/restore、DB破損、削除中killを試す。下書きと未送信はevictionせず、完全消去を過大保証しない。

## 制約

添付OCR・PDF本文検索は今回対象外。LIKE全文scanやunicode61だけを日本語検索完成として出荷しない。

## この依頼の進め方と提出物

最初に未完了の縦切り機能を1つ選び、変更範囲と試験を短く示して実装する。API・permission・依存版は採用ADRと公式資料で確認する。各縦切り機能を完了してから次へ進む。

完了時は変更差分、AC ID、実行コマンドと結果、3OS CI状態、異常系の証拠、未実施チェック、既知制限を報告し、`docs/status.md`を更新する。Phase全体のgateが未達なら完了と宣言しない。外部資格情報等が必要でも、安全に実装・ローカル検証できる範囲を先に完成させ、必要な外部準備を具体的に列挙する。
