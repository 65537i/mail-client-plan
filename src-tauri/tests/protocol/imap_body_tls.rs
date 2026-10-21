use std::{future::pending, io::ErrorKind, sync::Arc, time::Duration};

use async_imap::Client;
use rustls::pki_types::ServerName;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    time::Instant,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

use super::{CheckedFetchError, SOURCE, owned_checked_fetch};

async fn exercise_tls_fetch(complete_literal: bool, cancel: Option<bool>) {
    tokio::time::timeout(Duration::from_secs(5), async {
        let (client_config, server_config) = super::super::imap_tls_configs();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (mut signal_tx, mut signal_rx) = tokio::io::duplex(1);
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            tcp.set_nodelay(true).unwrap();
            let tls = TlsAcceptor::from(Arc::new(server_config))
                .accept(tcp)
                .await
                .unwrap();
            let mut stream = BufReader::new(tls);
            stream
                .get_mut()
                .write_all(b"* OK synthetic TLS peer\r\n")
                .await
                .unwrap();
            stream.get_mut().flush().await.unwrap();
            super::super::read_command(
                &mut stream,
                "A0001 LOGIN \"synthetic@example.invalid\" \"SYNTHETIC-PASSWORD\"\r\n",
            )
            .await;
            stream
                .get_mut()
                .write_all(b"A0001 OK authenticated\r\n")
                .await
                .unwrap();
            stream.get_mut().flush().await.unwrap();
            super::super::read_command(
                &mut stream,
                "A0002 UID FETCH 8 (UID FLAGS BODY.PEEK[])\r\n",
            )
            .await;
            stream
                .get_mut()
                .write_all(format!("* 1 FETCH (UID 8 BODY[] {{{}}}\r\n", SOURCE.len()).as_bytes())
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
            stream.get_mut().flush().await.unwrap();
            if cancel.is_none() {
                stream
                    .get_mut()
                    .write_all(b"A0002 OK fetched\r\n")
                    .await
                    .unwrap();
                stream.get_mut().flush().await.unwrap();
                super::super::read_command(&mut stream, "A0003 NOOP\r\n").await;
                stream
                    .get_mut()
                    .write_all(b"A0003 OK noop\r\n")
                    .await
                    .unwrap();
                stream.get_mut().flush().await.unwrap();
            } else {
                signal_tx.write_u8(1).await.unwrap();
            }
            let mut after = Vec::new();
            let closure = stream.read_to_end(&mut after).await;
            match closure {
                Ok(count) => assert_eq!(count, 0),
                Err(error) => assert_eq!(error.kind(), ErrorKind::UnexpectedEof),
            }
            assert!(
                after.is_empty(),
                "closed FETCH must not send further commands"
            );
        });
        let tcp = TcpStream::connect(address).await.unwrap();
        tcp.set_nodelay(true).unwrap();
        let tls = TlsConnector::from(Arc::new(client_config))
            .connect(ServerName::try_from("localhost").unwrap(), tcp)
            .await
            .unwrap();
        let mut client = Client::new(tls);
        assert!(client.read_response().await.unwrap().is_some());
        let session = client
            .login("synthetic@example.invalid", "SYNTHETIC-PASSWORD")
            .await
            .map_err(|(error, _)| error)
            .unwrap();
        let cancellation = async {
            if cancel == Some(true) {
                assert_eq!(signal_rx.read_u8().await.unwrap(), 1);
                tokio::time::sleep(Duration::from_millis(20)).await;
            } else {
                pending::<()>().await;
            }
        };
        let deadline = Instant::now()
            + if cancel == Some(false) {
                Duration::from_millis(200)
            } else {
                Duration::from_secs(2)
            };
        let result = owned_checked_fetch(session, deadline, cancellation).await;
        match cancel {
            None => {
                let (mut session, raw) = result.unwrap();
                assert_eq!(raw, SOURCE);
                assert!(mail_client_lib::mime_poc::parse(&raw).is_ok());
                session.run_command_and_check_ok("NOOP").await.unwrap();
                drop(session);
            }
            Some(cancel) => {
                let failure = result.unwrap_err();
                assert!(!format!("{failure:?}").contains("Synthetic"));
                let (cause, provisional) = failure.into_parts();
                assert_eq!(
                    cause,
                    if cancel {
                        CheckedFetchError::Cancelled
                    } else {
                        CheckedFetchError::TimedOut
                    }
                );
                assert_eq!(
                    provisional.as_deref(),
                    if complete_literal { Some(SOURCE) } else { None }
                );
            }
        }
        server.await.unwrap();
    })
    .await
    .expect("TLS FETCH and peer closure must finish within the deadline");
}

#[tokio::test]
async fn ac04_owned_fetch_succeeds_over_verified_tls_and_returns_usable_session() {
    exercise_tls_fetch(true, None).await;
}

#[tokio::test]
async fn ac04_owned_fetch_closes_tls_on_interruption_and_recovers_complete_literal() {
    for complete in [false, true] {
        for cancel in [false, true] {
            exercise_tls_fetch(complete, Some(cancel)).await;
        }
    }
}
