# Phase 00: 技術検証・脅威モデル・CI骨格

この指示は`prompts/00-master.md`と設計書を前提とする。現在のリポジトリを調べ、既存実装を活かして進めてください。

## 前提

なし。既存リポジトリは調査してから拡張する。

## 受け入れ基準

`docs/02-acceptance-tests.md`のAC-00、AC-05/06/18/22の技術PoC。関連する既存ACを回帰させない。

## 順番に実装する縦切り機能

### 00A: 最小起動と依存固定

実装: Tauri 2 + Vue 3 + TypeScript strictの最小アプリとRust workspaceを用意する。Node/Rust/package managerとlockfileを固定し、3OS native build CIを作る。OS/arch/最低版とrunnerを実機候補付きでADR-001へ記録する。

検証: 3OSでbuild、起動、終了できる。古いTauri 1の設定を混ぜない。

### 00B: 危険な境界のPoC

実装: メールのscript、CSS、CID、リンクを含む合成HTMLを用意し、sandboxとCSPの試作品を実WebViewで試す。カスタムcommandを明示permission化して、本文から呼べないことを確認する。SecretStoreの保存/lock/拒否/削除も試す。

検証: 外部通信・IPC・ファイル参照を監視し、攻撃が遮断される。権限設定とテスト結果をADR-003/004へ保存する。

### 00C: 依存・検索・E2E検証

実装: IMAP候補のTLS/XOAUTH2/UID/IDLE、SMTPの受理エラー取得、MIME耐性、trigramの日本語、3OS WebdriverIO方式を小さい検証で比較する。plaintext cache許容を設計前提として明示する。

検証: ADR-002/005/006/007/008が埋まり、未対応拡張のfallbackと本番からテストpluginを除外する方法が定まる。

## 制約

まだ実サーバの利用者メールを取得しない。採用できないライブラリ機能があればPoC失敗を記録し、安全な代替を選ぶ。

## この依頼の進め方と提出物

最初に未完了の縦切り機能を1つ選び、変更範囲と試験を短く示して実装する。API・permission・依存版は採用ADRと公式資料で確認する。各縦切り機能を完了してから次へ進む。

完了時は変更差分、AC ID、実行コマンドと結果、3OS CI状態、異常系の証拠、未実施チェック、既知制限を報告し、`docs/status.md`を更新する。Phase全体のgateが未達なら完了と宣言しない。外部資格情報等が必要でも、安全に実装・ローカル検証できる範囲を先に完成させ、必要な外部準備を具体的に列挙する。
