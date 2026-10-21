use async_imap::{Client, types::Flag};
use futures_util::StreamExt;
use mail_client_lib::mime_poc;
use tokio::io::{AsyncWriteExt, BufReader};

const SOURCE: &[u8] = b"Subject: Synthetic body\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic literal\r\n)\r\nA0003 OK not a protocol response\r\n";

async fn exercise_body_fetch(fragment_size: usize, truncate: bool) {
    tokio::time::timeout(std::time::Duration::from_secs(3), async {
        let (client_stream, server_stream) = tokio::io::duplex(128);
        let server = tokio::spawn(async move {
            let mut stream = BufReader::new(server_stream);
            stream
                .get_mut()
                .write_all(b"* OK synthetic peer\r\n")
                .await
                .unwrap();
            super::read_command(
                &mut stream,
                "A0001 LOGIN \"synthetic@example.invalid\" \"SYNTHETIC-PASSWORD\"\r\n",
            )
            .await;
            stream
                .get_mut()
                .write_all(b"A0001 OK authenticated\r\n")
                .await
                .unwrap();
            super::read_command(&mut stream, "A0002 EXAMINE \"INBOX\"\r\n").await;
            stream.get_mut().write_all(
                b"* 1 EXISTS\r\n* OK [UIDVALIDITY 4242] stable\r\nA0002 OK [READ-ONLY] examined\r\n"
            ).await.unwrap();
            super::read_command(&mut stream, "A0003 UID FETCH 8 (UID FLAGS BODY.PEEK[])\r\n").await;
            stream
                .get_mut()
                .write_all(
                    format!("* 1 FETCH (UID 8 FLAGS () BODY[] {{{}}}\r\n", SOURCE.len()).as_bytes(),
                )
                .await
                .unwrap();
            let bytes = if truncate {
                &SOURCE[..SOURCE.len() / 2]
            } else {
                SOURCE
            };
            for chunk in bytes.chunks(fragment_size) {
                stream.get_mut().write_all(chunk).await.unwrap();
                tokio::task::yield_now().await;
            }
            if truncate {
                stream.get_mut().shutdown().await.unwrap();
                return;
            }
            stream
                .get_mut()
                .write_all(b")\r\nA0003 OK fetched\r\n")
                .await
                .unwrap();
            super::read_command(&mut stream, "A0004 UID FETCH 8 (UID FLAGS)\r\n").await;
            stream
                .get_mut()
                .write_all(b"* 1 FETCH (UID 8 FLAGS ())\r\nA0004 OK flags unchanged\r\n")
                .await
                .unwrap();
            super::read_command(&mut stream, "A0005 LOGOUT\r\n").await;
            stream
                .get_mut()
                .write_all(b"* BYE finished\r\nA0005 OK logout\r\n")
                .await
                .unwrap();
        });

        let mut client = Client::new(client_stream);
        assert!(client.read_response().await.unwrap().is_some());
        let mut session = client
            .login("synthetic@example.invalid", "SYNTHETIC-PASSWORD")
            .await
            .map_err(|(error, _)| error)
            .unwrap();
        let mailbox = session.examine("INBOX").await.unwrap();
        assert_eq!(mailbox.uid_validity, Some(4242));
        let mut fetches = session
            .uid_fetch("8", "(UID FLAGS BODY.PEEK[])")
            .await
            .unwrap();
        if truncate {
            let mut saw_error = false;
            while let Some(result) = fetches.next().await {
                assert!(
                    result.is_err(),
                    "partial literal must not become a successful FETCH"
                );
                saw_error = true;
            }
            assert!(saw_error, "truncated literal must report an error");
            drop(fetches);
            drop(session);
        } else {
            let fetch = fetches.next().await.unwrap().unwrap();
            assert_eq!(fetch.uid, Some(8));
            assert!(fetch.flags().all(|flag| flag != Flag::Seen));
            let raw = fetch.body().expect("complete literal body");
            assert_eq!(raw, SOURCE);
            let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
            assert_eq!(message.subject(), Some("Synthetic body"));
            assert_eq!(
                message.body_text(0).as_deref(),
                Some("Synthetic literal\r\n)\r\nA0003 OK not a protocol response\r\n")
            );
            assert_eq!(diagnostics, mime_poc::MimeDiagnostics::default());
            assert!(fetches.next().await.is_none());
            drop(fetches);
            let mut flags = session.uid_fetch("8", "(UID FLAGS)").await.unwrap();
            let fetch = flags.next().await.unwrap().unwrap();
            assert_eq!(fetch.uid, Some(8));
            assert!(fetch.flags().all(|flag| flag != Flag::Seen));
            assert!(flags.next().await.is_none());
            drop(flags);
            session.logout().await.unwrap();
        }
        server.await.unwrap();
    })
    .await
    .expect("synthetic body FETCH must finish within the test deadline");
}

#[tokio::test]
async fn ac04_body_peek_reassembles_literals_and_preserves_unseen_flags() {
    for fragment_size in [1, 17, SOURCE.len()] {
        exercise_body_fetch(fragment_size, false).await;
    }
}

#[tokio::test]
async fn ac04_truncated_body_literal_is_not_a_successful_fetch() {
    exercise_body_fetch(7, true).await;
}
