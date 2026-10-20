# ADR-006: 日本語trigram検索PoC

- 状態: 暫定。SQLite FTS5 trigramで日本語部分一致・NFKC・account scopeをローカルfixtureで確認。実データ規模とPhase 07統合は未検証
- 決定日: 2026-10-20

## 背景

FTS5 `unicode61` tokenizerは日本語の一般的な部分文字列検索を提供しない。AC-18では3文字以上の日本語部分一致、正規化、account scope、短いqueryの制限をPhase 00で試作する。Phase 07の10万件性能基準は別途実データ相当fixtureで確認する。

## 選択肢

- FTS5 `unicode61`: 日本語の連続文字列を適切な単語境界へ分けないため、部分一致候補として不採用。
- 通常の`LIKE '%query%'`: 小規模PoCには使えるが、無制限の全行scanになるため検索の主経路にはしない。
- FTS5 `trigram`: 3文字以上の部分一致候補として採用し、SQLite同梱版で検証する。

## 決定

- Rust PoCを`search-poc` Cargo feature下に置き、bundled SQLiteのFTS5 trigram virtual tableで検索する。本番default buildにはPoCのrusqlite / normalization依存を含めない。
- index投入時とquery時にUnicode NFKCおよび空白整理を行う。日本語・全角英数・半角カタカナの入力を同じ正規化形で照合できることをfixtureで確認する。
- queryを二重引用符で囲んだparameterized MATCH句として生成し、FTS演算子として解釈させず文字列部分一致にする。account IDも別parameterでDB条件に含める。
- trigram MATCHは正規化後3 Unicode scalar value未満を受け付けず、明示的なエラーにする。このPoCでは短いquery用LIKE fallbackやUIは実装しない。

## 実験条件と結果

| 確認 | 結果 |
|---|---|
| 日本語の中間substring | `東京でメールを読む`から`東京で`・`メール`がヒット |
| NFKC | 全角英数`ＡＢＣ`を`ABC`で照合し、半角カタカナのfixtureも正規化後に一致 |
| account scope | 同じ本文を持つ異なるaccountのfixtureをaccount条件で分離 |
| 短いquery | 正規化後1〜2文字と空白のみのqueryをindex query前に拒否 |
| FTS構文文字列 | `OR`を含むqueryをquoted literal substringとして検索 |
| 実行 | `cargo test -p mail-client --features search-poc --test japanese_trigram_search --locked` |

## 未達・制限

- PoCは小さなin-memory fixtureであり、100,000件・平均10KiB、100 queryのp95 1秒基準、DB増加量、書込み/削除時のFTS整合性は測定していない。
- NFKC/空白規則のversion永続化、結合文字・濁点・英語大小文字等の契約fixture、FTS同期transaction、structured query AST、cancel/timeout/件数上限はPhase 07で実装する。
- 1〜2文字queryの上限付きscope検索とUI案内は未実装。無制限LIKE scanへfallbackしてはならない。
- 検索対象はindex済みsubject/bodyとし、添付OCRは対象外。未取得本文の扱いはPhase 07で明示する。

## 再評価条件

日本語fixtureで部分一致が欠落する、NFKCが意図しない別語衝突を生む、account scopeがDBで強制できない、または性能基準を満たさない場合は、tokenizer・正規化・index構造を再評価する。性能失敗を無制限LIKE scanで隠さない。
