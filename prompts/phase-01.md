# Phase 01: 型付きIPC・永続化・UI基盤

この指示は`prompts/00-master.md`と設計書を前提とする。現在のリポジトリを調べ、既存実装を活かして進めてください。

## 前提

Phase 00の採用ADRと3OS build gateが成立。

## 受け入れ基準

`docs/02-acceptance-tests.md`のAC-01、AC-02。関連する既存ACを回帰させない。

## 順番に実装する縦切り機能

### 01A: domainと契約

実装: AccountId/FolderId/MessageRef、取得状態、error分類を作り、型付きIPCとDTOを用意する。別account参照を拒否するuse caseを実装する。

検証: 不正payload/境界外ID/未知commandを実IPCまたは契約試験で拒否する。

### 01B: DBとmigration

実装: accounts/folders/messages/blobs/schema_migrationsを作る。FK、unique、WAL、profile lock、単一writer、migration backup/失敗処理を実装する。

検証: 空DB→最新版、旧版fixture→最新版、途中失敗、二重起動を試す。

### 01C: fixture UI

実装: 3ペイン、account切替、keyset一覧、loading/empty/errorを合成データで作る。package scriptsとCIを実在する処理へ接続する。

検証: UI component試験と3OS起動。件名等はtextとして表示し、未実装機能は成功しない。

## 制約

ネットワーク取得や本物の資格情報をまだ追加しない。DB層をフロントへ公開しない。

## この依頼の進め方と提出物

最初に未完了の縦切り機能を1つ選び、変更範囲と試験を短く示して実装する。API・permission・依存版は採用ADRと公式資料で確認する。各縦切り機能を完了してから次へ進む。

完了時は変更差分、AC ID、実行コマンドと結果、3OS CI状態、異常系の証拠、未実施チェック、既知制限を報告し、`docs/status.md`を更新する。Phase全体のgateが未達なら完了と宣言しない。外部資格情報等が必要でも、安全に実装・ローカル検証できる範囲を先に完成させ、必要な外部準備を具体的に列挙する。
