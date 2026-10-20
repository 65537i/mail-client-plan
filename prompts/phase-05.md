# Phase 05: SMTP・下書き・返信転送・永続Outbox

この指示は`prompts/00-master.md`と設計書を前提とする。現在のリポジトリを調べ、既存実装を活かして進めてください。

## 前提

Phase 04完了。SMTPの受理応答と不明区間のADRが確定。

## 受け入れ基準

`docs/02-acceptance-tests.md`のAC-12、AC-13、AC-14、AC-15。関連する既存ACを回帰させない。

## 順番に実装する縦切り機能

### 05A: 下書きとMIME

実装: プレーン作成、返信/全員返信/転送、添付、identity確認、自動保存を実装する。アドレス解析と改行注入拒否、Bcc envelope分離を行う。

検証: 日本語、References、全員返信の自分除外、Bcc非漏洩、再起動復元を試す。

### 05B: Outbox state machine

実装: revision付き下書きからimmutable MIME snapshotを作りoperationIdでenqueueする。SMTP final acceptance、failed、unknownを永続化し、再開時にも不明状態を保持する。

検証: 連打で1job。DATA前失敗は限定retry、終端付近/応答不明/accepted保存前killは自動再送0回。RCPT一部拒否時DATAなし。

### 05C: Sent保存とUX

実装: SMTP成功とSent APPENDを独立追跡し、provider自動保存方針を適用する。unknown確認、明示再送、送信元表示、送信前確認を作る。

検証: SMTP sinkの配送数で検証する。APPEND失敗でSMTP再送なし、queuedの添付を編集/削除しても送信snapshot不変。

## 制約

外部へ実送信せず、relay禁止のsinkで検証する。Message-IDで重複が防げると仮定しない。リッチHTML編集は後回しでよい。

## この依頼の進め方と提出物

最初に未完了の縦切り機能を1つ選び、変更範囲と試験を短く示して実装する。API・permission・依存版は採用ADRと公式資料で確認する。各縦切り機能を完了してから次へ進む。

完了時は変更差分、AC ID、実行コマンドと結果、3OS CI状態、異常系の証拠、未実施チェック、既知制限を報告し、`docs/status.md`を更新する。Phase全体のgateが未達なら完了と宣言しない。外部資格情報等が必要でも、安全に実装・ローカル検証できる範囲を先に完成させ、必要な外部準備を具体的に列挙する。
