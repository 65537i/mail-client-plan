use async_imap::{
    Client,
    imap_proto::{AttributeValue, Response, Status},
    types::Flag,
};
use futures_util::StreamExt;
use mail_client_lib::mime_poc;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    time::Instant,
};

const SOURCE: &[u8] = b"Subject: Synthetic body\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic literal\r\n)\r\nA0003 OK not a protocol response\r\n";

#[derive(Clone, Copy)]
enum FetchEnd {
    Complete,
    TruncatedLiteral,
    No,
    Bad,
    MissingCompletion,
    WrongTag,
    MissingBody,
}

async fn owned_checked_fetch(
    mut session: async_imap::Session<tokio::io::DuplexStream>,
    deadline: Instant,
    cancellation: impl std::future::Future<Output = ()>,
) -> Result<(async_imap::Session<tokio::io::DuplexStream>, Vec<u8>), CheckedFetchError> {
    let timeout = async {
        if Instant::now() < deadline {
            tokio::time::sleep_until(deadline).await;
        }
    };
    let body = tokio::select! {
        biased;
        () = cancellation => return Err(CheckedFetchError::Cancelled),
        () = timeout => return Err(CheckedFetchError::TimedOut),
        result = checked_fetch(&mut session) => result?,
    };
    Ok((session, body))
}

#[derive(Debug, PartialEq, Eq)]
enum CheckedFetchError {
    Io,
    MissingCompletion,
    Rejected,
    UnexpectedResponse,
    MissingBody,
    TimedOut,
    Cancelled,
}

// Evaluation only: the candidate still buffers literals without a size gate.
async fn checked_fetch(
    session: &mut async_imap::Session<tokio::io::DuplexStream>,
) -> Result<Vec<u8>, CheckedFetchError> {
    let tag = session
        .run_command("UID FETCH 8 (UID FLAGS BODY.PEEK[])")
        .await
        .map_err(|_| CheckedFetchError::Io)?;
    let mut body = None;
    loop {
        let response = session
            .read_response()
            .await
            .map_err(|_| CheckedFetchError::Io)?
            .ok_or(CheckedFetchError::MissingCompletion)?;
        match response.parsed() {
            Response::Fetch(_, attributes) => {
                if !attributes
                    .iter()
                    .any(|attr| matches!(attr, AttributeValue::Uid(8)))
                {
                    return Err(CheckedFetchError::UnexpectedResponse);
                }
                for attribute in attributes {
                    if let AttributeValue::BodySection {
                        section: None,
                        data: Some(bytes),
                        ..
                    } = attribute
                    {
                        if body.is_some() {
                            return Err(CheckedFetchError::UnexpectedResponse);
                        }
                        body = Some(bytes.to_vec());
                    }
                }
            }
            Response::Done {
                tag: received,
                status,
                ..
            } => {
                if received != &tag {
                    return Err(CheckedFetchError::UnexpectedResponse);
                }
                return if *status == Status::Ok {
                    body.ok_or(CheckedFetchError::MissingBody)
                } else {
                    Err(CheckedFetchError::Rejected)
                };
            }
            _ => return Err(CheckedFetchError::UnexpectedResponse),
        }
    }
}

async fn exercise_fetch(fragment_size: usize, end: FetchEnd) {
    exercise_fetch_api(fragment_size, end, false).await;
}

async fn exercise_fetch_api(fragment_size: usize, end: FetchEnd, checked: bool) {
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
            if matches!(end, FetchEnd::MissingBody) {
                stream
                    .get_mut()
                    .write_all(b"A0003 OK no matching message\r\n")
                    .await
                    .unwrap();
                stream.get_mut().shutdown().await.unwrap();
                if checked {
                    let mut after = Vec::new();
                    stream.read_to_end(&mut after).await.unwrap();
                    assert!(
                        after.is_empty(),
                        "failed FETCH must close without another command"
                    );
                }
                return;
            }
            stream
                .get_mut()
                .write_all(
                    format!("* 1 FETCH (UID 8 FLAGS () BODY[] {{{}}}\r\n", SOURCE.len()).as_bytes(),
                )
                .await
                .unwrap();
            let bytes = if matches!(end, FetchEnd::TruncatedLiteral) {
                &SOURCE[..SOURCE.len() / 2]
            } else {
                SOURCE
            };
            for chunk in bytes.chunks(fragment_size) {
                stream.get_mut().write_all(chunk).await.unwrap();
                tokio::task::yield_now().await;
            }
            if matches!(end, FetchEnd::TruncatedLiteral) {
                stream.get_mut().shutdown().await.unwrap();
                if checked {
                    let mut after = Vec::new();
                    stream.read_to_end(&mut after).await.unwrap();
                    assert!(
                        after.is_empty(),
                        "failed FETCH must close without another command"
                    );
                }
                return;
            }
            if !matches!(end, FetchEnd::Complete) {
                stream.get_mut().write_all(b")\r\n").await.unwrap();
                match end {
                    FetchEnd::No => stream
                        .get_mut()
                        .write_all(b"A0003 NO synthetic failure\r\n")
                        .await
                        .unwrap(),
                    FetchEnd::Bad => stream
                        .get_mut()
                        .write_all(b"A0003 BAD synthetic rejection\r\n")
                        .await
                        .unwrap(),
                    FetchEnd::MissingCompletion => {}
                    FetchEnd::WrongTag => stream
                        .get_mut()
                        .write_all(b"A9999 OK unrelated command\r\n")
                        .await
                        .unwrap(),
                    _ => unreachable!(),
                }
                stream.get_mut().shutdown().await.unwrap();
                if checked {
                    let mut after = Vec::new();
                    stream.read_to_end(&mut after).await.unwrap();
                    assert!(
                        after.is_empty(),
                        "failed FETCH must close without another command"
                    );
                }
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
        if checked {
            let result = owned_checked_fetch(
                session,
                Instant::now() + std::time::Duration::from_secs(2),
                std::future::pending(),
            )
            .await;
            match end {
                FetchEnd::Complete => {
                    let (mut session, raw) = result.unwrap();
                    assert_eq!(raw, SOURCE);
                    assert!(mime_poc::parse(&raw).is_ok());
                    let mut flags = session.uid_fetch("8", "(UID FLAGS)").await.unwrap();
                    assert_eq!(flags.next().await.unwrap().unwrap().uid, Some(8));
                    assert!(flags.next().await.is_none());
                    drop(flags);
                    session.logout().await.unwrap();
                }
                FetchEnd::No | FetchEnd::Bad => {
                    assert_eq!(result.map(|_| ()), Err(CheckedFetchError::Rejected))
                }
                FetchEnd::MissingCompletion => {
                    assert_eq!(
                        result.map(|_| ()),
                        Err(CheckedFetchError::MissingCompletion)
                    )
                }
                FetchEnd::WrongTag => {
                    assert_eq!(
                        result.map(|_| ()),
                        Err(CheckedFetchError::UnexpectedResponse)
                    )
                }
                FetchEnd::TruncatedLiteral => {
                    assert_eq!(result.map(|_| ()), Err(CheckedFetchError::Io))
                }
                FetchEnd::MissingBody => {
                    assert_eq!(result.map(|_| ()), Err(CheckedFetchError::MissingBody))
                }
            }
            server.await.unwrap();
            return;
        }

        let mut fetches = session
            .uid_fetch("8", "(UID FLAGS BODY.PEEK[])")
            .await
            .unwrap();
        if matches!(end, FetchEnd::TruncatedLiteral) {
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
        } else if !matches!(end, FetchEnd::Complete) {
            let provisional = fetches.next().await.unwrap().unwrap();
            assert_eq!(provisional.uid, Some(8));
            assert_eq!(provisional.body(), Some(SOURCE));
            assert!(mime_poc::parse(provisional.body().unwrap()).is_ok());
            // Candidate limitation: stream termination does not prove tagged OK.
            // Keep production adoption blocked until completion is observable.
            assert!(
                fetches.next().await.is_none(),
                "re-evaluate the adoption blocker if the candidate starts reporting failure"
            );
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
        exercise_fetch(fragment_size, FetchEnd::Complete).await;
    }
}

#[tokio::test]
async fn ac04_truncated_body_literal_is_not_a_successful_fetch() {
    exercise_fetch(7, FetchEnd::TruncatedLiteral).await;
}

#[tokio::test]
async fn ac04_candidate_limitation_hides_tagged_no_or_bad_after_body() {
    for end in [FetchEnd::No, FetchEnd::Bad] {
        exercise_fetch(17, end).await;
    }
}

#[tokio::test]
async fn ac04_candidate_limitation_ends_without_tagged_completion() {
    exercise_fetch(17, FetchEnd::MissingCompletion).await;
}

#[tokio::test]
async fn ac04_checked_fetch_requires_matching_tagged_ok_before_returning_body() {
    for size in [1, 17, SOURCE.len()] {
        exercise_fetch_api(size, FetchEnd::Complete, true).await;
    }
}

#[tokio::test]
async fn ac04_checked_fetch_rejects_failure_missing_completion_and_wrong_tags() {
    for end in [
        FetchEnd::No,
        FetchEnd::Bad,
        FetchEnd::MissingCompletion,
        FetchEnd::WrongTag,
        FetchEnd::TruncatedLiteral,
        FetchEnd::MissingBody,
    ] {
        exercise_fetch_api(17, end, true).await;
    }
}

#[tokio::test]
async fn ac04_owned_fetch_closes_stalled_session_on_cancel_or_deadline() {
    for complete_literal in [false, true] {
        for cancel in [false, true] {
            tokio::time::timeout(std::time::Duration::from_secs(3), async {
                let (client_stream, server_stream) = tokio::io::duplex(4096);
                let (mut signal_tx, mut signal_rx) = tokio::io::duplex(1);
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
                    super::read_command(
                        &mut stream,
                        "A0002 UID FETCH 8 (UID FLAGS BODY.PEEK[])\r\n",
                    )
                    .await;
                    stream
                        .get_mut()
                        .write_all(
                            format!("* 1 FETCH (UID 8 BODY[] {{{}}}\r\n", SOURCE.len()).as_bytes(),
                        )
                        .await
                        .unwrap();
                    if complete_literal {
                        stream.get_mut().write_all(SOURCE).await.unwrap();
                        stream.get_mut().write_all(b")\r\n").await.unwrap();
                    } else {
                        stream
                            .get_mut()
                            .write_all(&SOURCE[..SOURCE.len() / 2])
                            .await
                            .unwrap();
                    }
                    signal_tx.write_u8(1).await.unwrap();
                    let mut after = Vec::new();
                    stream.read_to_end(&mut after).await.unwrap();
                    assert!(
                        after.is_empty(),
                        "interrupted session must close without retry, NOOP or LOGOUT"
                    );
                });
                let mut client = Client::new(client_stream);
                assert!(client.read_response().await.unwrap().is_some());
                let session = client
                    .login("synthetic@example.invalid", "SYNTHETIC-PASSWORD")
                    .await
                    .map_err(|(error, _)| error)
                    .unwrap();
                let cancellation = async {
                    assert_eq!(signal_rx.read_u8().await.unwrap(), 1);
                    if cancel {
                        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                    } else {
                        std::future::pending::<()>().await;
                    }
                };
                let result = owned_checked_fetch(
                    session,
                    Instant::now() + std::time::Duration::from_millis(100),
                    cancellation,
                )
                .await;
                assert_eq!(
                    result.map(|_| ()),
                    Err(if cancel {
                        CheckedFetchError::Cancelled
                    } else {
                        CheckedFetchError::TimedOut
                    })
                );
                server.await.unwrap();
            })
            .await
            .expect("owned FETCH interruption must close the peer");
        }
    }
}

#[tokio::test]
async fn ac04_owned_fetch_ready_cancel_and_expired_deadline_send_no_command() {
    for cancel in [false, true] {
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            let (client_stream, server_stream) = tokio::io::duplex(4096);
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
                let mut after = Vec::new();
                stream.read_to_end(&mut after).await.unwrap();
                assert!(after.is_empty());
            });
            let mut client = Client::new(client_stream);
            assert!(client.read_response().await.unwrap().is_some());
            let session = client
                .login("synthetic@example.invalid", "SYNTHETIC-PASSWORD")
                .await
                .map_err(|(error, _)| error)
                .unwrap();
            let result = owned_checked_fetch(session, Instant::now(), async {
                if !cancel {
                    std::future::pending::<()>().await;
                }
            })
            .await;
            assert_eq!(
                result.map(|_| ()),
                Err(if cancel {
                    CheckedFetchError::Cancelled
                } else {
                    CheckedFetchError::TimedOut
                })
            );
            server.await.unwrap();
        })
        .await
        .expect("preempted FETCH must close without sending a command");
    }
}
