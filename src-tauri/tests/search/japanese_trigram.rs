use rusqlite::{Connection, params};
use unicode_normalization::UnicodeNormalization;

fn normalize(text: &str) -> String {
    text.nfkc()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn prepare_match_query(query: &str) -> Result<String, &'static str> {
    let normalized = normalize(query);
    if normalized.chars().count() < 3 {
        return Err("search requires at least three normalized characters");
    }

    Ok(format!("\"{}\"", normalized.replace('"', "\"\"")))
}

fn create_index() -> Connection {
    let connection = Connection::open_in_memory().expect("open in-memory SQLite");
    connection
        .execute_batch(
            "CREATE VIRTUAL TABLE message_fts USING fts5(
                account_id UNINDEXED,
                subject,
                body,
                tokenize = 'trigram'
            );",
        )
        .expect("create FTS5 trigram index");
    connection
}

fn insert_message(connection: &Connection, account_id: &str, subject: &str, body: &str) {
    connection
        .execute(
            "INSERT INTO message_fts (account_id, subject, body) VALUES (?1, ?2, ?3)",
            params![account_id, normalize(subject), normalize(body)],
        )
        .expect("insert normalized message");
}

fn search(connection: &Connection, account_id: &str, query: &str) -> Vec<i64> {
    let match_query = prepare_match_query(query).expect("valid three-character search query");
    let mut statement = connection
        .prepare(
            "SELECT rowid FROM message_fts
             WHERE message_fts MATCH ?1 AND account_id = ?2
             ORDER BY rowid",
        )
        .expect("prepare scoped trigram query");
    statement
        .query_map(params![match_query, account_id], |row| row.get(0))
        .expect("execute scoped trigram query")
        .collect::<rusqlite::Result<Vec<i64>>>()
        .expect("collect search results")
}

#[test]
fn ac18_matches_japanese_substrings_and_normalizes_fullwidth_text() {
    let connection = create_index();
    insert_message(&connection, "account-a", "ﾒｰﾙ ＡＢＣ", "東京でメールを読む");

    assert_eq!(search(&connection, "account-a", "東京で"), vec![1]);
    assert_eq!(search(&connection, "account-a", "メール"), vec![1]);
    assert_eq!(search(&connection, "account-a", "ABC"), vec![1]);
}

#[test]
fn ac18_enforces_account_scope_and_rejects_queries_shorter_than_three_characters() {
    let connection = create_index();
    insert_message(&connection, "account-a", "東京でのメール", "");
    insert_message(&connection, "account-b", "東京でのメール", "");

    assert_eq!(search(&connection, "account-a", "東京で"), vec![1]);
    assert_eq!(search(&connection, "account-b", "東京で"), vec![2]);
    assert_eq!(search(&connection, "account-a", "メール"), vec![1]);
    assert!(search(&connection, "account-c", "東京で").is_empty());
    assert!(prepare_match_query("東").is_err());
    assert!(prepare_match_query("東京").is_err());
    assert!(prepare_match_query("  東京  ").is_err());
    assert!(prepare_match_query("東京で").is_ok());
}

#[test]
fn ac18_quotes_fts_syntax_as_literal_substring_text() {
    let connection = create_index();
    insert_message(&connection, "account-a", "hello OR world", "");

    assert_eq!(search(&connection, "account-a", "OR w"), vec![1]);
}
