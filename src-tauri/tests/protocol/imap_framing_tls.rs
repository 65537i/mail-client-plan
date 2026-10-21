use std::{future::Future, io::ErrorKind, sync::Arc, time::Duration};

use rustls::pki_types::ServerName;
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::Instant,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

use super::{BoundedFramingProbe, FramingError, INPUT_CHUNK_BYTES, fetch_response};

#[path = "imap_bounded_fetch.rs"]
mod fetch;

#[derive(Debug, PartialEq, Eq)]
enum ReceiveError {
    Framing(FramingError),
    Eof,
    Io(ErrorKind),
    TimedOut,
    Cancelled,
}

struct ReceiveFailure {
    cause: ReceiveError,
    prefix: Vec<u8>,
}

impl std::fmt::Debug for ReceiveFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ReceiveFailure")
            .field("cause", &self.cause)
            .field("prefix_bytes", &self.prefix.len())
            .finish()
    }
}

struct BoundedReceiver<T> {
    stream: T,
    framing: BoundedFramingProbe,
}

impl<T: AsyncRead + Unpin> BoundedReceiver<T> {
    async fn receive(
        mut self,
        deadline: Instant,
        cancellation: impl Future<Output = ()>,
    ) -> Result<(Self, Vec<u8>), ReceiveFailure> {
        let mut progressed = false;
        match self
            .read_response(deadline, cancellation, &mut progressed)
            .await
        {
            Ok(response) => Ok((self, response)),
            Err(cause) => Err(ReceiveFailure {
                cause,
                prefix: if progressed {
                    self.framing.fragments.message_bytes().to_vec()
                } else {
                    Vec::new()
                },
            }),
        }
    }

    async fn read_response(
        &mut self,
        deadline: Instant,
        cancellation: impl Future<Output = ()>,
        progressed: &mut bool,
    ) -> Result<Vec<u8>, ReceiveError> {
        *progressed = false;
        tokio::pin!(cancellation);
        loop {
            let step = async {
                *progressed = true;
                if let Some(response) = self
                    .framing
                    .next_response()
                    .map_err(ReceiveError::Framing)?
                {
                    return Ok(Some(response));
                }
                let mut chunk = [0; INPUT_CHUNK_BYTES];
                match self.stream.read(&mut chunk).await {
                    Ok(0) => Err(ReceiveError::Eof),
                    Ok(count) => {
                        self.framing.fragments.enqueue_bytes(&chunk[..count]);
                        Ok(None)
                    }
                    Err(error) if error.kind() == ErrorKind::Interrupted => Ok(None),
                    Err(error) => Err(ReceiveError::Io(error.kind())),
                }
            };
            let timeout = async {
                if Instant::now() < deadline {
                    tokio::time::sleep_until(deadline).await;
                }
            };
            let result = tokio::select! {
                biased;
                () = &mut cancellation => Err(ReceiveError::Cancelled),
                () = timeout => Err(ReceiveError::TimedOut),
                result = step => result,
            };
            match result {
                Ok(Some(response)) => return Ok(response),
                Ok(None) => tokio::task::yield_now().await,
                Err(error) => return Err(error),
            }
        }
    }
}

#[derive(Clone, Copy)]
enum End {
    Complete,
    Oversized,
    ResponseLimit,
    Decode,
    Eof,
    Deadline,
    Cancel,
}

async fn exercise_tls(end: End) {
    tokio::time::timeout(Duration::from_secs(5), async {
        let (client_config, server_config) = super::super::super::imap_tls_configs();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let completion = b"A0002 OK synthetic completion\r\n";
        let partial = b"* 1 FETCH (UID 8 BODY[] {64}\r\npartial";
        let header = format!(
            "* 1 FETCH (UID 8 BODY[] {{{}}}\r\n",
            mail_client_lib::mime_poc::MAX_RAW_BYTES + 1
        );
        let payload = match end {
            End::Complete => {
                let mut bytes = fetch_response(super::super::SOURCE);
                bytes.extend_from_slice(completion);
                bytes
            }
            End::Oversized => {
                let mut bytes = header.as_bytes().to_vec();
                bytes.push(b'x');
                bytes
            }
            End::ResponseLimit => vec![b'x'; 129],
            End::Decode => b"* invalid synthetic response\r\n".to_vec(),
            _ => partial.to_vec(),
        };
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut tls = TlsAcceptor::from(Arc::new(server_config))
                .accept(tcp)
                .await
                .unwrap();
            tls.write_all(&payload).await.unwrap();
            tls.flush().await.unwrap();
            if matches!(end, End::Eof) {
                tls.shutdown().await.unwrap();
            }
            let mut after = Vec::new();
            match tls.read_to_end(&mut after).await {
                Ok(count) => assert_eq!(count, 0),
                Err(error) => assert_eq!(error.kind(), ErrorKind::UnexpectedEof),
            }
            assert!(after.is_empty(), "receiver failure must not write commands");
        });
        let tls = TlsConnector::from(Arc::new(client_config))
            .connect(
                ServerName::try_from("localhost").unwrap(),
                TcpStream::connect(address).await.unwrap(),
            )
            .await
            .unwrap();
        let limit = u32::try_from(mail_client_lib::mime_poc::MAX_RAW_BYTES).unwrap();
        let receiver = BoundedReceiver {
            stream: tls,
            framing: BoundedFramingProbe::new(
                limit,
                if matches!(end, End::ResponseLimit) {
                    128
                } else {
                    limit + 4096
                },
            ),
        };
        let deadline = Instant::now() + Duration::from_millis(250);
        let cancellation = async {
            if matches!(end, End::Cancel) {
                tokio::time::sleep(Duration::from_millis(50)).await;
            } else {
                std::future::pending::<()>().await;
            }
        };
        match receiver.receive(deadline, cancellation).await {
            Ok((receiver, response)) => {
                assert!(matches!(end, End::Complete));
                assert_eq!(response, fetch_response(super::super::SOURCE));
                let (receiver, response) = receiver
                    .receive(deadline, std::future::pending())
                    .await
                    .unwrap();
                assert_eq!(response, completion);
                drop(receiver);
            }
            Err(failure) => {
                let expected = match end {
                    End::Oversized => ReceiveError::Framing(FramingError::LiteralTooLarge),
                    End::ResponseLimit => ReceiveError::Framing(FramingError::ResponseTooLarge),
                    End::Decode => ReceiveError::Framing(FramingError::Decode),
                    End::Eof => ReceiveError::Eof,
                    End::Deadline => ReceiveError::TimedOut,
                    End::Cancel => ReceiveError::Cancelled,
                    End::Complete => panic!("complete input must succeed: {failure:?}"),
                };
                assert_eq!(failure.cause, expected);
                assert_eq!(
                    failure.prefix,
                    match end {
                        End::Oversized => header.as_bytes(),
                        End::ResponseLimit => &[b'x'; 128],
                        End::Decode => b"* invalid synthetic response\r\n",
                        _ => partial,
                    }
                );
                assert!(!format!("{failure:?}").contains("partial"));
                assert!(!format!("{failure:?}").contains("synthetic"));
            }
        }
        server.await.unwrap();
    })
    .await
    .expect("bounded TLS receive and peer closure must complete");
}

#[tokio::test]
async fn ac04_bounded_tls_receiver_preserves_coalesced_following_response() {
    exercise_tls(End::Complete).await;
}

#[tokio::test]
async fn ac04_bounded_tls_receiver_closes_on_limit_eof_deadline_or_cancel() {
    for end in [
        End::Oversized,
        End::ResponseLimit,
        End::Decode,
        End::Eof,
        End::Deadline,
        End::Cancel,
    ] {
        exercise_tls(end).await;
    }
}
