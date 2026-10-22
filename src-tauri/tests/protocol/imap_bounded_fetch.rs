use std::{future::Future, io::ErrorKind, sync::Arc, time::Duration};

use async_imap::Client;
use imap_codec_framing::{
    ResponseCodec,
    decode::Decoder,
    imap_types::{
        fetch::MessageDataItem,
        response::{Data, Response, Status, StatusKind},
    },
};
use rustls::{ClientConfig, RootCertStore, pki_types::ServerName};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    time::Instant,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

use super::{BoundedFramingProbe, BoundedReceiver, FramingError, ReceiveError};

const COMMAND: &[u8] = b"F0001 UID FETCH 8 (UID FLAGS BODY.PEEK[])\r\n";
const SOURCE: &[u8] = super::super::super::SOURCE;

#[path = "imap_fetch_io.rs"]
mod io_tests;

#[derive(Debug, PartialEq, Eq)]
enum FetchError {
    Receive(ReceiveError),
    Write(ErrorKind),
    UnexpectedResponse,
    Rejected,
    MissingBody,
    TimedOut,
    Cancelled,
}

struct FetchFailure {
    cause: FetchError,
    provisional: Option<Vec<u8>>,
    wire_prefix: Vec<u8>,
}

impl std::fmt::Debug for FetchFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FetchFailure")
            .field("cause", &self.cause)
            .field(
                "provisional_bytes",
                &self.provisional.as_ref().map(Vec::len),
            )
            .field("wire_prefix_bytes", &self.wire_prefix.len())
            .finish()
    }
}

fn check_response(raw: &[u8], body: &mut Option<Vec<u8>>) -> Result<bool, FetchError> {
    let (remaining, response) = ResponseCodec::default()
        .decode(raw)
        .map_err(|_| FetchError::UnexpectedResponse)?;
    if !remaining.is_empty() {
        return Err(FetchError::UnexpectedResponse);
    }
    match response {
        Response::Data(Data::Fetch { items, .. }) => {
            let mut uids = items.as_ref().iter().filter_map(|item| match item {
                MessageDataItem::Uid(uid) => Some(uid.get()),
                _ => None,
            });
            if uids.next() != Some(8) || uids.next().is_some() {
                return Err(FetchError::UnexpectedResponse);
            }
            for item in items.as_ref() {
                match item {
                    MessageDataItem::BodyExt {
                        section: None,
                        origin: None,
                        data,
                    } if body.is_none() => {
                        let bytes = data.0.as_ref().ok_or(FetchError::MissingBody)?;
                        *body = Some(bytes.as_ref().to_vec());
                    }
                    MessageDataItem::Uid(_) | MessageDataItem::Flags(_) => {}
                    _ => return Err(FetchError::UnexpectedResponse),
                }
            }
            Ok(false)
        }
        Response::Status(Status::Tagged(tagged)) => {
            if tagged.tag.as_ref() != "F0001" {
                return Err(FetchError::UnexpectedResponse);
            }
            if tagged.body.kind != StatusKind::Ok {
                return Err(FetchError::Rejected);
            }
            if body.is_none() {
                return Err(FetchError::MissingBody);
            }
            Ok(true)
        }
        _ => Err(FetchError::UnexpectedResponse),
    }
}

// Fixed-command evaluation only; this is not an authenticated mailbox session.
async fn checked_fetch<T>(
    mut receiver: BoundedReceiver<T>,
    deadline: Instant,
    cancellation: impl Future<Output = ()>,
) -> Result<(BoundedReceiver<T>, Vec<u8>), FetchFailure>
where
    T: AsyncRead + AsyncWrite + Unpin,
{
    let mut provisional = None;
    let mut progressed = false;
    let operation = async {
        receiver
            .stream
            .write_all(COMMAND)
            .await
            .map_err(|error| FetchError::Write(error.kind()))?;
        receiver
            .stream
            .flush()
            .await
            .map_err(|error| FetchError::Write(error.kind()))?;
        loop {
            let raw = receiver
                .read_response(deadline, std::future::pending(), &mut progressed)
                .await
                .map_err(FetchError::Receive)?;
            if check_response(&raw, &mut provisional)? {
                return Ok(());
            }
            progressed = false;
            tokio::task::yield_now().await;
        }
    };
    let timeout = async {
        if Instant::now() < deadline {
            tokio::time::sleep_until(deadline).await;
        }
    };
    let result = tokio::select! {
        biased;
        () = cancellation => Err(FetchError::Cancelled),
        () = timeout => Err(FetchError::TimedOut),
        result = operation => result,
    };
    match result {
        Ok(()) => Ok((
            receiver,
            provisional.expect("checked matching OK requires body"),
        )),
        Err(cause) => Err(FetchFailure {
            cause,
            provisional,
            wire_prefix: if progressed {
                receiver.framing.fragments.message_bytes().to_vec()
            } else {
                Vec::new()
            },
        }),
    }
}

#[derive(Clone, Copy, Debug)]
enum End {
    Complete,
    Sequence(ResponseSequence),
    No,
    Bad,
    WrongTag,
    WrongUid,
    MissingUid,
    DuplicateUid,
    DuplicateBody,
    Partial,
    MissingBody,
    Oversized,
    MissingCompletion,
    Truncated,
    Deadline,
    Cancel,
    PartialDeadline,
    PartialCancel,
    CompletionDeadline,
    CompletionCancel,
}

#[derive(Clone, Copy, Debug)]
enum ResponseSequence {
    FlagsBeforeBody,
    FlagsAfterBody,
    SecondLiteral,
    WrongUidAfterBody,
    MissingUidAfterBody,
    PartialAfterBody,
    NilAfterBody,
}

#[derive(Clone, Copy, Debug)]
enum StartTlsEnd {
    Complete,
    Refused,
    UntrustedCertificate,
    HostnameMismatch,
    OversizedLiteral,
    TruncatedLiteral,
    StalledLiteral { cancel: bool },
    StalledCompletion { cancel: bool },
}

impl End {
    fn succeeds(self) -> bool {
        matches!(
            self,
            Self::Complete
                | Self::Sequence(
                    ResponseSequence::FlagsBeforeBody | ResponseSequence::FlagsAfterBody
                )
        )
    }
}

async fn exercise(end: End, fragment: usize) {
    tokio::time::timeout(Duration::from_secs(5), async {
        let (client_config, server_config) = super::super::super::super::imap_tls_configs();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            tcp.set_nodelay(true).unwrap();
            let tls = TlsAcceptor::from(Arc::new(server_config))
                .accept(tcp)
                .await
                .unwrap();
            let mut peer = BufReader::new(tls);
            super::super::super::super::read_command(
                &mut peer,
                std::str::from_utf8(COMMAND).unwrap(),
            )
            .await;
            let uid = match end {
                End::WrongUid => "UID 9 ",
                End::MissingUid => "",
                End::DuplicateUid => "UID 8 UID 9 ",
                _ => "UID 8 ",
            };
            let section = if matches!(end, End::Partial) {
                "BODY[]<0>"
            } else {
                "BODY[]"
            };
            let length = if matches!(end, End::Oversized) {
                mail_client_lib::mime_poc::MAX_RAW_BYTES + 1
            } else {
                SOURCE.len()
            };
            let mut payload = format!("* 1 FETCH ({uid}{section} {{{length}}}\r\n").into_bytes();
            if matches!(
                end,
                End::Truncated | End::Oversized | End::PartialDeadline | End::PartialCancel
            ) {
                payload.extend_from_slice(&SOURCE[..7]);
            } else if matches!(end, End::MissingBody) {
                payload = b"* 1 FETCH (UID 8 FLAGS ())\r\n".to_vec();
            } else {
                payload.extend_from_slice(SOURCE);
                if matches!(end, End::DuplicateBody) {
                    payload.extend_from_slice(b" BODY[] {9}\r\nuntrusted");
                }
                payload.extend_from_slice(b")\r\n");
            }
            if let End::Sequence(sequence) = end {
                match sequence {
                    ResponseSequence::FlagsBeforeBody => {
                        let mut responses = b"* 1 FETCH (UID 8 FLAGS ())\r\n".to_vec();
                        responses.extend_from_slice(&payload);
                        payload = responses;
                    }
                    ResponseSequence::FlagsAfterBody => {
                        payload.extend_from_slice(b"* 1 FETCH (UID 8 FLAGS (\\Flagged))\r\n");
                    }
                    ResponseSequence::SecondLiteral => {
                        payload.extend_from_slice(b"* 1 FETCH (UID 8 BODY[] {9}\r\nuntrusted)\r\n");
                    }
                    ResponseSequence::WrongUidAfterBody => {
                        payload.extend_from_slice(b"* 2 FETCH (UID 9 FLAGS ())\r\n");
                    }
                    ResponseSequence::MissingUidAfterBody => {
                        payload.extend_from_slice(b"* 1 FETCH (FLAGS ())\r\n");
                    }
                    ResponseSequence::PartialAfterBody => {
                        payload.extend_from_slice(
                            b"* 1 FETCH (UID 8 BODY[]<17> {9}\r\nuntrusted)\r\n",
                        );
                    }
                    ResponseSequence::NilAfterBody => {
                        payload.extend_from_slice(b"* 1 FETCH (UID 8 BODY[] NIL)\r\n");
                    }
                }
            }
            if matches!(end, End::CompletionDeadline | End::CompletionCancel) {
                payload.extend_from_slice(b"F0001 OK incomplete");
            }
            let completion: &[u8] = match end {
                End::No => b"F0001 NO synthetic rejection\r\n",
                End::Bad => b"F0001 BAD synthetic rejection\r\n",
                End::WrongTag => b"F9999 OK wrong command\r\n",
                End::Truncated
                | End::Oversized
                | End::MissingCompletion
                | End::Deadline
                | End::Cancel
                | End::PartialDeadline
                | End::PartialCancel
                | End::CompletionDeadline
                | End::CompletionCancel => b"",
                _ => b"F0001 OK fetched\r\n",
            };
            payload.extend_from_slice(completion);
            for chunk in payload.chunks(fragment) {
                peer.get_mut().write_all(chunk).await.unwrap();
            }
            peer.get_mut().flush().await.unwrap();
            if matches!(end, End::MissingCompletion | End::Truncated) {
                peer.get_mut().shutdown().await.unwrap();
            }
            if end.succeeds() {
                super::super::super::super::read_command(&mut peer, "F0002 NOOP\r\n").await;
                peer.get_mut()
                    .write_all(b"F0002 OK noop\r\n")
                    .await
                    .unwrap();
                peer.get_mut().flush().await.unwrap();
            }
            let mut after = Vec::new();
            match peer.read_to_end(&mut after).await {
                Ok(count) => assert_eq!(count, 0),
                Err(error) => assert_eq!(error.kind(), ErrorKind::UnexpectedEof),
            }
            assert!(
                after.is_empty(),
                "failed FETCH must not send subsequent commands"
            );
        });
        let tcp = TcpStream::connect(address).await.unwrap();
        tcp.set_nodelay(true).unwrap();
        let tls = TlsConnector::from(Arc::new(client_config))
            .connect(ServerName::try_from("localhost").unwrap(), tcp)
            .await
            .unwrap();
        let limit = u32::try_from(mail_client_lib::mime_poc::MAX_RAW_BYTES).unwrap();
        let receiver = BoundedReceiver {
            stream: tls,
            framing: BoundedFramingProbe::new(limit, limit + 4096),
        };
        let deadline = Instant::now() + Duration::from_millis(500);
        let cancellation = async {
            if matches!(
                end,
                End::Cancel | End::PartialCancel | End::CompletionCancel
            ) {
                tokio::time::sleep(Duration::from_millis(100)).await;
            } else {
                std::future::pending::<()>().await;
            }
        };
        match checked_fetch(receiver, deadline, cancellation).await {
            Ok((mut receiver, raw)) => {
                assert!(end.succeeds());
                assert_eq!(raw, SOURCE);
                assert!(mail_client_lib::mime_poc::parse(&raw).is_ok());
                receiver.stream.write_all(b"F0002 NOOP\r\n").await.unwrap();
                receiver.stream.flush().await.unwrap();
                let (receiver, raw) = receiver
                    .receive(
                        Instant::now() + Duration::from_secs(1),
                        std::future::pending(),
                    )
                    .await
                    .unwrap();
                assert_eq!(raw, b"F0002 OK noop\r\n");
                drop(receiver);
            }
            Err(failure) => {
                let expected = match end {
                    End::No | End::Bad => FetchError::Rejected,
                    End::WrongTag
                    | End::WrongUid
                    | End::MissingUid
                    | End::DuplicateUid
                    | End::DuplicateBody
                    | End::Partial => FetchError::UnexpectedResponse,
                    End::Sequence(
                        ResponseSequence::FlagsBeforeBody | ResponseSequence::FlagsAfterBody,
                    ) => panic!("same-UID flags must not invalidate the body: {failure:?}"),
                    End::Sequence(_) => FetchError::UnexpectedResponse,
                    End::MissingBody => FetchError::MissingBody,
                    End::Oversized => {
                        FetchError::Receive(ReceiveError::Framing(FramingError::LiteralTooLarge))
                    }
                    End::MissingCompletion | End::Truncated => {
                        FetchError::Receive(ReceiveError::Eof)
                    }
                    End::Deadline | End::PartialDeadline | End::CompletionDeadline => {
                        FetchError::TimedOut
                    }
                    End::Cancel | End::PartialCancel | End::CompletionCancel => {
                        FetchError::Cancelled
                    }
                    End::Complete => panic!("normal FETCH failed: {failure:?}"),
                };
                assert_eq!(failure.cause, expected, "{end:?}");
                let retain_body = matches!(
                    end,
                    End::No
                        | End::Bad
                        | End::WrongTag
                        | End::DuplicateBody
                        | End::MissingCompletion
                        | End::Deadline
                        | End::Cancel
                        | End::Sequence(_)
                        | End::CompletionDeadline
                        | End::CompletionCancel
                );
                assert_eq!(
                    failure.provisional.as_deref(),
                    if retain_body { Some(SOURCE) } else { None }
                );
                assert!(!format!("{failure:?}").contains("Synthetic"));
                if matches!(
                    end,
                    End::Truncated | End::Oversized | End::PartialDeadline | End::PartialCancel
                ) {
                    let length = if matches!(end, End::Oversized) {
                        mail_client_lib::mime_poc::MAX_RAW_BYTES + 1
                    } else {
                        SOURCE.len()
                    };
                    let mut expected =
                        format!("* 1 FETCH (UID 8 BODY[] {{{length}}}\r\n").into_bytes();
                    if !matches!(end, End::Oversized) {
                        expected.extend_from_slice(&SOURCE[..7]);
                    }
                    assert_eq!(failure.wire_prefix, expected);
                }
                if matches!(end, End::Deadline | End::Cancel) {
                    assert!(
                        failure.wire_prefix.is_empty(),
                        "completed response is not a new partial prefix"
                    );
                }
                if matches!(end, End::CompletionDeadline | End::CompletionCancel) {
                    assert_eq!(failure.wire_prefix, b"F0001 OK incomplete", "{end:?}");
                }
            }
        }
        server.await.unwrap();
    })
    .await
    .expect("bounded TLS FETCH and peer shutdown must finish");
}

async fn exercise_starttls_fetch(end: StartTlsEnd) {
    tokio::time::timeout(Duration::from_secs(5), async {
        let (trusted_config, server_config) = super::super::super::super::imap_tls_configs();
        let client_config = if matches!(end, StartTlsEnd::UntrustedCertificate) {
            ClientConfig::builder()
                .with_root_certificates(RootCertStore::empty())
                .with_no_client_auth()
        } else {
            trusted_config
        };
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut plain = BufReader::new(tcp);
            plain
                .get_mut()
                .write_all(b"* OK synthetic STARTTLS peer\r\n")
                .await
                .unwrap();
            plain.get_mut().flush().await.unwrap();
            super::super::super::super::read_command(&mut plain, "A0001 STARTTLS\r\n").await;
            if matches!(end, StartTlsEnd::Refused) {
                plain
                    .get_mut()
                    .write_all(b"A0001 NO TLS unavailable\r\n")
                    .await
                    .unwrap();
                plain.get_mut().flush().await.unwrap();
                let mut trailing = Vec::new();
                let _ = plain.read_to_end(&mut trailing).await;
                assert!(trailing.is_empty(), "must not fall back to plaintext");
                return;
            }
            plain
                .get_mut()
                .write_all(b"A0001 OK begin TLS negotiation\r\n")
                .await
                .unwrap();
            plain.get_mut().flush().await.unwrap();
            let tcp = plain.into_inner();
            let tls_result = TlsAcceptor::from(Arc::new(server_config)).accept(tcp).await;
            if matches!(
                end,
                StartTlsEnd::UntrustedCertificate | StartTlsEnd::HostnameMismatch
            ) {
                assert!(
                    tls_result.is_err(),
                    "invalid TLS identity must stop the upgrade"
                );
                return;
            }
            let tls = tls_result.unwrap();
            let mut encrypted = BufReader::new(tls);
            super::super::super::super::read_command(
                &mut encrypted,
                std::str::from_utf8(COMMAND).unwrap(),
            )
            .await;
            let payload = match end {
                StartTlsEnd::OversizedLiteral => format!(
                    "* 1 FETCH (UID 8 BODY[] {{{}}}\r\nx",
                    mail_client_lib::mime_poc::MAX_RAW_BYTES + 1
                )
                .into_bytes(),
                StartTlsEnd::TruncatedLiteral | StartTlsEnd::StalledLiteral { .. } => {
                    let mut bytes = format!("* 1 FETCH (UID 8 BODY[] {{{}}}\r\n", SOURCE.len() + 7)
                        .into_bytes();
                    bytes.extend_from_slice(&SOURCE[..7]);
                    bytes
                }
                StartTlsEnd::Complete => {
                    let mut bytes = super::super::fetch_response(SOURCE);
                    bytes.extend_from_slice(b"F0001 OK fetched\r\n");
                    bytes
                }
                StartTlsEnd::StalledCompletion { .. } => {
                    let mut bytes = super::super::fetch_response(SOURCE);
                    bytes.extend_from_slice(b"F0001 OK incomplete");
                    bytes
                }
                _ => unreachable!("only successful TLS upgrades receive FETCH"),
            };
            encrypted.get_mut().write_all(&payload).await.unwrap();
            encrypted.get_mut().flush().await.unwrap();
            if matches!(
                end,
                StartTlsEnd::StalledLiteral { .. } | StartTlsEnd::StalledCompletion { .. }
            ) {
                ready_tx.send(()).unwrap();
            } else if matches!(end, StartTlsEnd::TruncatedLiteral) {
                encrypted.get_mut().shutdown().await.unwrap();
            } else if matches!(end, StartTlsEnd::Complete) {
                super::super::super::super::read_command(&mut encrypted, "F0002 NOOP\r\n").await;
                encrypted
                    .get_mut()
                    .write_all(b"F0002 OK noop\r\n")
                    .await
                    .unwrap();
                encrypted.get_mut().flush().await.unwrap();
            }
            let mut trailing = Vec::new();
            let _ = encrypted.read_to_end(&mut trailing).await;
            assert!(trailing.is_empty());
        });

        let tcp = TcpStream::connect(address).await.unwrap();
        let mut client = Client::new(tcp);
        assert!(client.read_response().await.unwrap().is_some());
        if matches!(end, StartTlsEnd::Refused) {
            assert!(
                client
                    .run_command_and_check_ok("STARTTLS", None)
                    .await
                    .is_err()
            );
            drop(client);
            server.await.unwrap();
            return;
        }
        client
            .run_command_and_check_ok("STARTTLS", None)
            .await
            .unwrap();
        let tcp = client.into_inner();
        let hostname = if matches!(end, StartTlsEnd::HostnameMismatch) {
            "wrong-hostname.invalid"
        } else {
            "localhost"
        };
        let tls = TlsConnector::from(Arc::new(client_config))
            .connect(ServerName::try_from(hostname).unwrap(), tcp)
            .await;
        if matches!(
            end,
            StartTlsEnd::UntrustedCertificate | StartTlsEnd::HostnameMismatch
        ) {
            assert!(tls.is_err(), "STARTTLS TLS identity must be verified");
            server.await.unwrap();
            return;
        }
        let tls = tls.unwrap();
        let limit = u32::try_from(mail_client_lib::mime_poc::MAX_RAW_BYTES).unwrap();
        let receiver = BoundedReceiver {
            stream: tls,
            framing: BoundedFramingProbe::new(limit, limit + 4096),
        };
        match end {
            StartTlsEnd::Complete => {
                let (mut receiver, raw) = checked_fetch(
                    receiver,
                    Instant::now() + Duration::from_secs(2),
                    std::future::pending(),
                )
                .await
                .unwrap();
                assert_eq!(raw, SOURCE);
                assert!(mail_client_lib::mime_poc::parse(&raw).is_ok());
                receiver.stream.write_all(b"F0002 NOOP\r\n").await.unwrap();
                receiver.stream.flush().await.unwrap();
                let (receiver, response) = receiver
                    .receive(
                        Instant::now() + Duration::from_secs(2),
                        std::future::pending(),
                    )
                    .await
                    .unwrap();
                assert_eq!(response, b"F0002 OK noop\r\n");
                drop(receiver);
            }
            StartTlsEnd::OversizedLiteral
            | StartTlsEnd::TruncatedLiteral
            | StartTlsEnd::StalledLiteral { .. }
            | StartTlsEnd::StalledCompletion { .. } => {
                let cancel = matches!(
                    end,
                    StartTlsEnd::StalledLiteral { cancel: true }
                        | StartTlsEnd::StalledCompletion { cancel: true }
                );
                let cancellation = async {
                    if matches!(
                        end,
                        StartTlsEnd::StalledLiteral { .. } | StartTlsEnd::StalledCompletion { .. }
                    ) {
                        ready_rx.await.unwrap();
                        if cancel {
                            tokio::time::sleep(Duration::from_millis(50)).await;
                            return;
                        }
                        std::future::pending::<()>().await;
                    } else {
                        std::future::pending::<()>().await;
                    }
                };
                let deadline = if cancel {
                    Instant::now() + Duration::from_secs(2)
                } else {
                    Instant::now() + Duration::from_secs(1)
                };
                let Err(failure) = checked_fetch(receiver, deadline, cancellation).await else {
                    panic!("STARTTLS FETCH interruption or malformed input must fail");
                };
                let expected = match end {
                    StartTlsEnd::OversizedLiteral => {
                        FetchError::Receive(ReceiveError::Framing(FramingError::LiteralTooLarge))
                    }
                    StartTlsEnd::TruncatedLiteral => FetchError::Receive(ReceiveError::Eof),
                    StartTlsEnd::StalledLiteral { cancel: true }
                    | StartTlsEnd::StalledCompletion { cancel: true } => FetchError::Cancelled,
                    StartTlsEnd::StalledLiteral { cancel: false }
                    | StartTlsEnd::StalledCompletion { cancel: false } => FetchError::TimedOut,
                    _ => unreachable!(),
                };
                assert_eq!(failure.cause, expected);
                match end {
                    StartTlsEnd::StalledCompletion { .. } => {
                        assert_eq!(failure.provisional.as_deref(), Some(SOURCE));
                        assert_eq!(failure.wire_prefix, b"F0001 OK incomplete");
                    }
                    StartTlsEnd::StalledLiteral { .. } => {
                        assert!(failure.provisional.is_none());
                        let mut prefix =
                            format!("* 1 FETCH (UID 8 BODY[] {{{}}}\r\n", SOURCE.len() + 7)
                                .into_bytes();
                        prefix.extend_from_slice(&SOURCE[..7]);
                        assert_eq!(failure.wire_prefix, prefix, "{end:?}");
                    }
                    StartTlsEnd::TruncatedLiteral => {
                        assert!(failure.provisional.is_none());
                    }
                    StartTlsEnd::OversizedLiteral => {
                        assert!(failure.provisional.is_none());
                    }
                    _ => unreachable!(),
                }
                assert!(!format!("{failure:?}").contains("Synthetic"));
            }
            _ => unreachable!(),
        }
        server.await.unwrap();
    })
    .await
    .expect("STARTTLS bounded FETCH flow must finish");
}

#[tokio::test]
async fn ac04_bounded_fetch_reuses_receiver_after_verified_starttls() {
    exercise_starttls_fetch(StartTlsEnd::Complete).await;
}

#[tokio::test]
async fn ac04_bounded_fetch_does_not_fallback_after_starttls_refusal() {
    exercise_starttls_fetch(StartTlsEnd::Refused).await;
}

#[tokio::test]
async fn ac04_bounded_fetch_stops_on_untrusted_or_mismatched_starttls_identity() {
    for end in [
        StartTlsEnd::UntrustedCertificate,
        StartTlsEnd::HostnameMismatch,
    ] {
        exercise_starttls_fetch(end).await;
    }
}

#[tokio::test]
async fn ac04_bounded_fetch_rejects_oversized_or_truncated_starttls_literal() {
    for end in [StartTlsEnd::OversizedLiteral, StartTlsEnd::TruncatedLiteral] {
        exercise_starttls_fetch(end).await;
    }
}

#[tokio::test]
async fn ac04_bounded_fetch_recovers_starttls_prefix_on_literal_and_completion_interruption() {
    for end in [
        StartTlsEnd::StalledLiteral { cancel: false },
        StartTlsEnd::StalledLiteral { cancel: true },
        StartTlsEnd::StalledCompletion { cancel: false },
        StartTlsEnd::StalledCompletion { cancel: true },
    ] {
        exercise_starttls_fetch(end).await;
    }
}

#[tokio::test]
async fn ac04_bounded_tls_fetch_accepts_same_uid_flags_before_or_after_body() {
    for sequence in [
        ResponseSequence::FlagsBeforeBody,
        ResponseSequence::FlagsAfterBody,
    ] {
        for fragment in [1, 17, 4096] {
            exercise(End::Sequence(sequence), fragment).await;
        }
    }
}

#[tokio::test]
async fn ac04_bounded_tls_fetch_recovers_wire_prefix_on_partial_literal_interruption() {
    for end in [
        End::PartialDeadline,
        End::PartialCancel,
        End::CompletionDeadline,
        End::CompletionCancel,
    ] {
        for fragment in [1, 17, 4096] {
            exercise(end, fragment).await;
        }
    }
}

#[tokio::test]
async fn ac04_bounded_tls_fetch_preserves_first_body_when_later_fetch_is_inconsistent() {
    for sequence in [
        ResponseSequence::SecondLiteral,
        ResponseSequence::WrongUidAfterBody,
        ResponseSequence::MissingUidAfterBody,
        ResponseSequence::PartialAfterBody,
        ResponseSequence::NilAfterBody,
    ] {
        for fragment in [1, 17, 4096] {
            exercise(End::Sequence(sequence), fragment).await;
        }
    }
}

#[tokio::test]
async fn ac04_bounded_tls_fetch_requires_checked_completion_and_returns_reusable_receiver() {
    for fragment in [1, 17, 4096] {
        exercise(End::Complete, fragment).await;
    }
}

#[tokio::test]
async fn ac04_bounded_tls_fetch_rejects_inconsistent_response_or_incomplete_transfer() {
    for end in [
        End::No,
        End::Bad,
        End::WrongTag,
        End::WrongUid,
        End::MissingUid,
        End::DuplicateUid,
        End::DuplicateBody,
        End::Partial,
        End::MissingBody,
        End::Oversized,
        End::MissingCompletion,
        End::Truncated,
    ] {
        exercise(end, 4096).await;
    }
}

#[tokio::test]
async fn ac04_bounded_tls_fetch_retains_provisional_body_when_completion_stalls() {
    for end in [End::Deadline, End::Cancel] {
        exercise(end, 4096).await;
    }
}

#[tokio::test]
async fn ac04_bounded_fetch_preflight_interruption_sends_no_command() {
    for cancel in [false, true] {
        let (stream, mut peer) = tokio::io::duplex(1024);
        peer.write_all(&super::super::fetch_response(SOURCE))
            .await
            .unwrap();
        let receiver = BoundedReceiver {
            stream,
            framing: BoundedFramingProbe::new(512, 1024),
        };
        let cancellation = async {
            if !cancel {
                std::future::pending::<()>().await;
            }
        };
        let Err(failure) = checked_fetch(receiver, Instant::now(), cancellation).await else {
            panic!("interrupted FETCH must not succeed");
        };
        assert_eq!(
            failure.cause,
            if cancel {
                FetchError::Cancelled
            } else {
                FetchError::TimedOut
            }
        );
        assert!(failure.provisional.is_none());
        assert!(failure.wire_prefix.is_empty());
        let mut command = Vec::new();
        tokio::time::timeout(Duration::from_secs(1), peer.read_to_end(&mut command))
            .await
            .unwrap()
            .unwrap();
        assert!(command.is_empty());
    }
}
