use std::collections::HashSet;
use std::{io::ErrorKind, sync::Arc};

#[cfg(feature = "mime-poc")]
#[path = "imap_body.rs"]
mod imap_body;

use async_imap::extensions::idle::IdleResponse;
use async_imap::imap_proto::{AttributeValue, MailboxDatum, Response, Status};
use async_imap::types::{Capability, Flag, UnsolicitedResponse};
use async_imap::{Authenticator, Client, Session};
use futures_util::StreamExt;
use rcgen::generate_simple_self_signed;
use rustls::{
    ClientConfig, RootCertStore, ServerConfig,
    pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer, ServerName},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
};
use tokio_rustls::{TlsAcceptor, TlsConnector, client::TlsStream as ClientTlsStream};

const SYNTHETIC_AUTH_RESPONSE: &[u8] =
    b"user=ac06@example.invalid\x01auth=Bearer SYNTHETIC-TOKEN\x01\x01";

const STARTTLS_FETCH_SOURCE: &[u8] =
    b"Subject: STARTTLS synthetic body\r\n\r\nBODY.PEEK source\r\n";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum FetchCompletion {
    Ok,
    No,
    Bad,
    WrongTag,
    Missing,
}

#[derive(Debug, PartialEq, Eq)]
enum FetchResult {
    Ok,
    Rejected,
    WrongTag,
    MissingCompletion,
    ReadError(ErrorKind),
    UnexpectedResponse,
}

#[derive(Debug, PartialEq, Eq)]
enum RawUidSearchResult {
    Complete(HashSet<u32>),
    DuplicateUids(HashSet<u32>),
    InvalidUids(HashSet<u32>),
    Rejected {
        status: SearchRejection,
        uids: HashSet<u32>,
    },
    MissingCompletion(HashSet<u32>),
    WrongTag(HashSet<u32>),
    ReadError {
        kind: ErrorKind,
        uids: HashSet<u32>,
    },
    UnexpectedResponse(HashSet<u32>),
}

#[derive(Debug, PartialEq, Eq)]
enum SearchRejection {
    No,
    Bad,
    Other,
}

struct SyntheticXoauth2;

impl Authenticator for SyntheticXoauth2 {
    type Response = Vec<u8>;

    fn process(&mut self, _challenge: &[u8]) -> Self::Response {
        SYNTHETIC_AUTH_RESPONSE.to_vec()
    }
}

async fn read_command<T: tokio::io::AsyncRead + Unpin>(stream: &mut BufReader<T>, expected: &str) {
    let mut command = String::new();
    stream
        .read_line(&mut command)
        .await
        .expect("read IMAP command line");
    assert_eq!(command, expected);
}

async fn raw_uid_search<T>(
    session: &mut Session<T>,
) -> Result<RawUidSearchResult, async_imap::error::Error>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + std::fmt::Debug + Send,
{
    let tag = session.run_command("UID SEARCH ALL").await?;
    let mut uids = HashSet::new();
    let mut wrong_tag = false;
    let mut duplicate_uid = false;
    let mut invalid_uid = false;
    loop {
        let response = match session.read_response().await {
            Ok(Some(response)) => response,
            Ok(None) => {
                return if wrong_tag {
                    Ok(RawUidSearchResult::WrongTag(uids))
                } else {
                    Ok(RawUidSearchResult::MissingCompletion(uids))
                };
            }
            Err(error) => {
                return Ok(RawUidSearchResult::ReadError {
                    kind: error.kind(),
                    uids,
                });
            }
        };
        match response.parsed() {
            Response::MailboxData(MailboxDatum::Search(values)) => {
                for uid in values.iter().copied() {
                    invalid_uid |= uid == 0;
                    duplicate_uid |= !uids.insert(uid);
                }
            }
            Response::Done {
                tag: response_tag,
                status,
                ..
            } if response_tag == &tag => {
                return if wrong_tag {
                    Ok(RawUidSearchResult::WrongTag(uids))
                } else if status == &Status::Ok {
                    Ok(if duplicate_uid {
                        RawUidSearchResult::DuplicateUids(uids)
                    } else if invalid_uid {
                        RawUidSearchResult::InvalidUids(uids)
                    } else {
                        RawUidSearchResult::Complete(uids)
                    })
                } else {
                    Ok(RawUidSearchResult::Rejected {
                        status: match status {
                            Status::No => SearchRejection::No,
                            Status::Bad => SearchRejection::Bad,
                            _ => SearchRejection::Other,
                        },
                        uids,
                    })
                };
            }
            Response::Done { .. } => wrong_tag = true,
            _ => return Ok(RawUidSearchResult::UnexpectedResponse(uids)),
        }
    }
}

async fn start_synthetic_imap_server() -> (tokio::io::DuplexStream, JoinHandle<std::io::Result<()>>)
{
    let (client_stream, server_stream) = tokio::io::duplex(4096);
    let task = tokio::spawn(async move {
        let mut stream = BufReader::new(server_stream);
        stream
            .get_mut()
            .write_all(b"* OK synthetic IMAP server ready\r\n")
            .await?;

        read_command(&mut stream, "A0001 AUTHENTICATE XOAUTH2\r\n").await;
        stream.get_mut().write_all(b"+ \r\n").await?;

        let mut auth_response = String::new();
        stream.read_line(&mut auth_response).await?;
        let decoded = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            auth_response.trim(),
        )
        .expect("decode synthetic SASL response");
        assert_eq!(decoded, SYNTHETIC_AUTH_RESPONSE);
        stream
            .get_mut()
            .write_all(b"A0001 OK authenticated\r\n")
            .await?;

        read_command(&mut stream, "A0002 SELECT \"INBOX\"\r\n").await;
        stream.get_mut().write_all(
            b"* 2 EXISTS\r\n* OK [UIDVALIDITY 4242] stable mailbox id\r\n* OK [UIDNEXT 9] next id\r\nA0002 OK [READ-WRITE] selected\r\n",
        ).await?;

        read_command(&mut stream, "A0003 UID FETCH 8 (UID FLAGS)\r\n").await;
        stream
            .get_mut()
            .write_all(b"* 2 FETCH (UID 8 FLAGS (\\Seen))\r\nA0003 OK fetch complete\r\n")
            .await?;

        let mut remaining = Vec::new();
        stream.read_to_end(&mut remaining).await?;
        Ok(())
    });

    (client_stream, task)
}

async fn start_idle_server(
    advertises_idle: bool,
) -> (tokio::io::DuplexStream, JoinHandle<std::io::Result<()>>) {
    let (client_stream, server_stream) = tokio::io::duplex(4096);
    let task = tokio::spawn(async move {
        let mut stream = BufReader::new(server_stream);
        stream
            .get_mut()
            .write_all(b"* OK synthetic IMAP server ready\r\n")
            .await?;

        read_command(
            &mut stream,
            "A0001 LOGIN \"synthetic@example.invalid\" \"SYNTHETIC-PASSWORD\"\r\n",
        )
        .await;
        stream
            .get_mut()
            .write_all(b"A0001 OK authenticated\r\n")
            .await?;
        read_command(&mut stream, "A0002 CAPABILITY\r\n").await;
        let capabilities = if advertises_idle {
            b"* CAPABILITY IMAP4rev1 IDLE\r\nA0002 OK capability complete\r\n".as_slice()
        } else {
            b"* CAPABILITY IMAP4rev1\r\nA0002 OK capability complete\r\n".as_slice()
        };
        stream.get_mut().write_all(capabilities).await?;

        if advertises_idle {
            read_command(&mut stream, "A0003 SELECT \"INBOX\"\r\n").await;
            stream
                .get_mut()
                .write_all(
                    b"* 0 EXISTS\r\n* OK [UIDVALIDITY 4242] selected\r\nA0003 OK selected\r\n",
                )
                .await?;
            read_command(&mut stream, "A0004 IDLE\r\n").await;
            stream.get_mut().write_all(b"+ idling\r\n").await?;
            read_command(&mut stream, "DONE\r\n").await;
            stream
                .get_mut()
                .write_all(b"A0004 OK IDLE terminated\r\n")
                .await?;
            read_command(&mut stream, "A0005 NOOP\r\n").await;
            stream
                .get_mut()
                .write_all(b"A0005 OK noop complete\r\n")
                .await?;
            read_command(&mut stream, "A0006 LOGOUT\r\n").await;
            stream
                .get_mut()
                .write_all(b"* BYE logging out\r\nA0006 OK logout complete\r\n")
                .await?;
        } else {
            read_command(&mut stream, "A0003 NOOP\r\n").await;
            stream
                .get_mut()
                .write_all(b"A0003 OK noop complete\r\n")
                .await?;
            read_command(&mut stream, "A0004 LOGOUT\r\n").await;
            stream
                .get_mut()
                .write_all(b"* BYE logging out\r\nA0004 OK logout complete\r\n")
                .await?;
        }

        let mut remaining = Vec::new();
        stream.read_to_end(&mut remaining).await?;
        Ok(())
    });

    (client_stream, task)
}

fn imap_tls_configs() -> (ClientConfig, ServerConfig) {
    let certificate = generate_simple_self_signed(vec!["localhost".to_string()])
        .expect("generate synthetic IMAP TLS certificate");
    let mut roots = RootCertStore::empty();
    roots
        .add(certificate.cert.der().clone())
        .expect("trust synthetic IMAP TLS certificate");
    let client = ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();
    let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        certificate.signing_key.serialize_der(),
    ));
    let server = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![certificate.cert.der().clone()], private_key)
        .expect("build synthetic IMAP TLS server config");
    (client, server)
}

async fn serve_authenticated_imap<T>(stream: T, send_greeting: bool) -> std::io::Result<()>
where
    T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let mut stream = BufReader::new(stream);
    if send_greeting {
        stream
            .get_mut()
            .write_all(b"* OK synthetic IMAP server ready\r\n")
            .await?;
    }
    read_command(&mut stream, "A0001 AUTHENTICATE XOAUTH2\r\n").await;
    stream.get_mut().write_all(b"+ \r\n").await?;
    let mut auth_response = String::new();
    stream.read_line(&mut auth_response).await?;
    let decoded = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        auth_response.trim(),
    )
    .expect("decode synthetic TLS SASL response");
    assert_eq!(decoded, SYNTHETIC_AUTH_RESPONSE);
    stream
        .get_mut()
        .write_all(b"A0001 OK authenticated\r\n")
        .await?;
    read_command(&mut stream, "A0002 LOGOUT\r\n").await;
    stream
        .get_mut()
        .write_all(b"* BYE logging out\r\nA0002 OK logout complete\r\n")
        .await?;
    Ok(())
}

async fn start_tls_imap_server(
    starttls: bool,
    config: ServerConfig,
) -> (std::net::SocketAddr, JoinHandle<std::io::Result<()>>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind synthetic TLS IMAP server");
    let address = listener
        .local_addr()
        .expect("read synthetic TLS IMAP address");
    let task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await?;
        let acceptor = TlsAcceptor::from(Arc::new(config));
        if starttls {
            let mut plain = BufReader::new(stream);
            plain
                .get_mut()
                .write_all(b"* OK synthetic IMAP server ready\r\n")
                .await?;
            read_command(&mut plain, "A0001 STARTTLS\r\n").await;
            plain
                .get_mut()
                .write_all(b"A0001 OK begin TLS negotiation\r\n")
                .await?;
            let tls = acceptor.accept(plain.into_inner()).await?;
            serve_authenticated_imap(tls, false).await
        } else {
            let tls = acceptor.accept(stream).await?;
            serve_authenticated_imap(tls, true).await
        }
    });
    (address, task)
}

async fn connect_candidate_tls(
    address: std::net::SocketAddr,
    config: ClientConfig,
) -> std::io::Result<ClientTlsStream<TcpStream>> {
    let stream = TcpStream::connect(address).await?;
    upgrade_candidate_tls(stream, config).await
}

async fn upgrade_candidate_tls(
    stream: TcpStream,
    config: ClientConfig,
) -> std::io::Result<ClientTlsStream<TcpStream>> {
    upgrade_candidate_tls_for_hostname(stream, config, "localhost").await
}

async fn upgrade_candidate_tls_for_hostname(
    stream: TcpStream,
    config: ClientConfig,
    hostname: &str,
) -> std::io::Result<ClientTlsStream<TcpStream>> {
    let server_name = ServerName::try_from(hostname.to_string())
        .map_err(|error| std::io::Error::new(ErrorKind::InvalidInput, error))?;
    TlsConnector::from(Arc::new(config))
        .connect(server_name, stream)
        .await
}

async fn candidate_authenticate_over_tls(
    address: std::net::SocketAddr,
    config: ClientConfig,
    hostname: &str,
) -> Result<(), String> {
    let stream = TcpStream::connect(address)
        .await
        .map_err(|error| error.to_string())?;
    let tls = upgrade_candidate_tls_for_hostname(stream, config, hostname)
        .await
        .map_err(|error| error.to_string())?;
    let mut client = Client::new(tls);
    client
        .read_response()
        .await
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "TLS IMAP greeting was missing".to_string())?;
    let session = client
        .authenticate("XOAUTH2", SyntheticXoauth2)
        .await
        .map_err(|(error, _client)| error.to_string())?;
    drop(session);
    Ok(())
}

async fn start_tls_auth_probe_server(
    config: ServerConfig,
) -> (std::net::SocketAddr, JoinHandle<std::io::Result<Vec<u8>>>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind synthetic TLS auth probe");
    let address = listener.local_addr().expect("read TLS auth probe address");
    let task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await?;
        let acceptor = TlsAcceptor::from(Arc::new(config));
        let Ok(mut tls) = acceptor.accept(stream).await else {
            return Ok(Vec::new());
        };

        tls.write_all(b"* OK synthetic IMAP server ready\r\n")
            .await?;
        let mut transcript = Vec::new();
        let mut command = Vec::new();
        tls.read_until(b'\n', &mut command).await?;
        transcript.extend_from_slice(&command);
        if command.starts_with(b"A0001 AUTHENTICATE XOAUTH2\r\n") {
            tls.write_all(b"+ \r\n").await?;
            let mut response = Vec::new();
            tls.read_until(b'\n', &mut response).await?;
            transcript.extend_from_slice(&response);
            tls.write_all(b"A0001 OK authenticated\r\n").await?;
        }
        tls.read_to_end(&mut transcript).await?;
        Ok(transcript)
    });
    (address, task)
}

#[tokio::test]
async fn candidate_supports_xoauth2_uidvalidity_and_uid_fetch_over_tokio() {
    let (stream, server) = start_synthetic_imap_server().await;
    let mut client = Client::new(stream);

    client
        .read_response()
        .await
        .expect("read greeting")
        .expect("server greeting must be present");

    let mut session = client
        .authenticate("XOAUTH2", SyntheticXoauth2)
        .await
        .map_err(|(error, _client)| error)
        .expect("authenticate with synthetic XOAUTH2");

    let mailbox = session
        .select("INBOX")
        .await
        .expect("select synthetic mailbox");
    assert_eq!(mailbox.uid_validity, Some(4242));
    assert_eq!(mailbox.uid_next, Some(9));

    let fetches = session
        .uid_fetch("8", "(UID FLAGS)")
        .await
        .expect("fetch by UID");
    let mut stream = Box::pin(fetches);
    let fetch = stream
        .next()
        .await
        .expect("one fetch response")
        .expect("fetch response parses");
    assert_eq!(fetch.uid, Some(8));
    assert!(fetch.flags().any(|flag| flag == Flag::Seen));
    assert!(stream.next().await.is_none());

    drop(stream);
    drop(session);
    server
        .await
        .expect("synthetic IMAP server task")
        .expect("synthetic IMAP server protocol");
}

#[tokio::test]
async fn candidate_accepts_rustls_stream_for_implicit_tls() {
    let (client_config, server_config) = imap_tls_configs();
    let (address, server) = start_tls_imap_server(false, server_config).await;
    let tls = connect_candidate_tls(address, client_config)
        .await
        .expect("verify and connect implicit TLS");
    let mut client = Client::new(tls);
    client
        .read_response()
        .await
        .expect("read greeting over TLS")
        .expect("TLS server greeting must be present");
    let mut session = client
        .authenticate("XOAUTH2", SyntheticXoauth2)
        .await
        .map_err(|(error, _client)| error)
        .expect("authenticate over verified TLS");
    session.logout().await.expect("logout over verified TLS");

    server
        .await
        .expect("synthetic implicit TLS server task")
        .expect("synthetic implicit TLS protocol");
}

#[tokio::test]
async fn candidate_sends_no_authentication_for_untrusted_tls_certificate() {
    let (_, server_config) = imap_tls_configs();
    let client_config = ClientConfig::builder()
        .with_root_certificates(RootCertStore::empty())
        .with_no_client_auth();
    let (address, server) = start_tls_auth_probe_server(server_config).await;

    assert!(
        candidate_authenticate_over_tls(address, client_config, "localhost")
            .await
            .is_err(),
        "an untrusted certificate must prevent IMAP authentication"
    );
    assert!(
        server
            .await
            .expect("untrusted TLS probe server task")
            .expect("read untrusted TLS probe transcript")
            .is_empty(),
        "no IMAP authentication data may reach an untrusted TLS peer"
    );
}

#[tokio::test]
async fn candidate_sends_no_authentication_for_hostname_mismatch() {
    let (client_config, server_config) = imap_tls_configs();
    let (address, server) = start_tls_auth_probe_server(server_config).await;

    assert!(
        candidate_authenticate_over_tls(address, client_config, "wrong.example")
            .await
            .is_err(),
        "a hostname mismatch must prevent IMAP authentication"
    );
    assert!(
        server
            .await
            .expect("hostname mismatch TLS probe server task")
            .expect("read hostname mismatch TLS probe transcript")
            .is_empty(),
        "no IMAP authentication data may reach a hostname-mismatched TLS peer"
    );
}

#[tokio::test]
async fn candidate_upgrades_starttls_before_authentication() {
    let (client_config, server_config) = imap_tls_configs();
    let (address, server) = start_tls_imap_server(true, server_config).await;
    let stream = TcpStream::connect(address)
        .await
        .expect("connect to synthetic STARTTLS server");
    let mut client = Client::new(stream);
    client
        .read_response()
        .await
        .expect("read plaintext greeting")
        .expect("STARTTLS server greeting must be present");
    client
        .run_command_and_check_ok("STARTTLS", None)
        .await
        .expect("require server to accept STARTTLS");

    let stream = client.into_inner();
    let tls = upgrade_candidate_tls(stream, client_config)
        .await
        .expect("verify and upgrade STARTTLS connection");
    let client = Client::new(tls);
    let mut session = client
        .authenticate("XOAUTH2", SyntheticXoauth2)
        .await
        .map_err(|(error, _client)| error)
        .expect("authenticate only after verified STARTTLS");
    session.logout().await.expect("logout over STARTTLS");

    server
        .await
        .expect("synthetic STARTTLS server task")
        .expect("synthetic STARTTLS protocol");
}

async fn exercise_starttls_authenticated_uid_fetch(completion: FetchCompletion) -> FetchResult {
    let (client_config, server_config) = imap_tls_configs();
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind synthetic STARTTLS session server");
    let address = listener
        .local_addr()
        .expect("read synthetic STARTTLS session address");
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await?;
        let acceptor = TlsAcceptor::from(Arc::new(server_config));
        let mut plaintext = BufReader::new(stream);
        plaintext
            .get_mut()
            .write_all(b"* OK synthetic IMAP server ready\r\n")
            .await?;
        read_command(&mut plaintext, "A0001 STARTTLS\r\n").await;
        plaintext
            .get_mut()
            .write_all(b"A0001 OK begin TLS negotiation\r\n")
            .await?;

        let tls = acceptor.accept(plaintext.into_inner()).await?;
        let mut encrypted = BufReader::new(tls);
        read_command(&mut encrypted, "A0001 AUTHENTICATE XOAUTH2\r\n").await;
        encrypted.get_mut().write_all(b"+ \r\n").await?;
        let mut auth_response = String::new();
        encrypted.read_line(&mut auth_response).await?;
        let decoded = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            auth_response.trim(),
        )
        .expect("decode synthetic STARTTLS XOAUTH2 response");
        assert_eq!(decoded, SYNTHETIC_AUTH_RESPONSE);
        encrypted
            .get_mut()
            .write_all(b"A0001 OK authenticated\r\n")
            .await?;

        read_command(&mut encrypted, "A0002 EXAMINE \"INBOX\"\r\n").await;
        encrypted
            .get_mut()
            .write_all(
                b"* 3 EXISTS\r\n* OK [UIDVALIDITY 4242] stable mailbox id\r\n* OK [UIDNEXT 10] next id\r\nA0002 OK [READ-ONLY] examined\r\n",
            )
            .await?;
        read_command(
            &mut encrypted,
            "A0003 UID FETCH 8 (UID FLAGS BODY.PEEK[])\r\n",
        )
        .await;
        let mut fetch = format!(
            "* 1 FETCH (UID 8 FLAGS () BODY[] {{{}}}\r\n",
            STARTTLS_FETCH_SOURCE.len()
        )
        .into_bytes();
        fetch.extend_from_slice(STARTTLS_FETCH_SOURCE);
        let final_response = match completion {
            FetchCompletion::Ok => b"A0003 OK fetched\r\n".as_slice(),
            FetchCompletion::No => b"A0003 NO fetch rejected\r\n",
            FetchCompletion::Bad => b"A0003 BAD invalid fetch\r\n",
            FetchCompletion::WrongTag => b"A9999 OK unrelated completion\r\n",
            FetchCompletion::Missing => b"",
        };
        fetch.extend_from_slice(b")\r\n");
        fetch.extend_from_slice(final_response);
        encrypted.get_mut().write_all(&fetch).await?;
        encrypted.get_mut().flush().await?;
        if matches!(completion, FetchCompletion::Missing) {
            encrypted.get_mut().shutdown().await?;
        }
        if !matches!(completion, FetchCompletion::Ok) {
            let mut unexpected_commands = Vec::new();
            let _ = encrypted.read_to_end(&mut unexpected_commands).await;
            assert!(
                unexpected_commands.is_empty(),
                "failed FETCH must not be followed by another command"
            );
            return Ok::<_, std::io::Error>(());
        }
        read_command(&mut encrypted, "A0004 LOGOUT\r\n").await;
        encrypted
            .get_mut()
            .write_all(b"* BYE logging out\r\nA0004 OK logout complete\r\n")
            .await?;
        Ok::<_, std::io::Error>(())
    });

    let stream = TcpStream::connect(address)
        .await
        .expect("connect to synthetic STARTTLS session server");
    let mut client = Client::new(stream);
    client
        .read_response()
        .await
        .expect("read plaintext greeting")
        .expect("STARTTLS session server greeting must be present");
    client
        .run_command_and_check_ok("STARTTLS", None)
        .await
        .expect("require STARTTLS before authentication");

    let tls = upgrade_candidate_tls(client.into_inner(), client_config)
        .await
        .expect("verify and upgrade STARTTLS connection");
    let client = Client::new(tls);
    let mut session = client
        .authenticate("XOAUTH2", SyntheticXoauth2)
        .await
        .map_err(|(error, _client)| error)
        .expect("authenticate over verified STARTTLS");
    let mailbox = session
        .examine("INBOX")
        .await
        .expect("examine INBOX without changing its flags");
    assert_eq!(mailbox.uid_validity, Some(4242));
    assert_eq!(mailbox.uid_next, Some(10));

    let fetch_tag = session
        .run_command("UID FETCH 8 (UID FLAGS BODY.PEEK[])")
        .await
        .expect("fetch the fixed UID with BODY.PEEK");
    let mut fetched_body = None;
    let fetch_result = 'responses: loop {
        let response = match session.read_response().await {
            Ok(Some(response)) => response,
            Ok(None) => break FetchResult::MissingCompletion,
            Err(error) => break FetchResult::ReadError(error.kind()),
        };
        match response.parsed() {
            Response::Fetch(_, attributes) => {
                let mut uids = attributes.iter().filter_map(|attribute| match attribute {
                    AttributeValue::Uid(uid) => Some(*uid),
                    _ => None,
                });
                if uids.next() != Some(8) || uids.next().is_some() {
                    break FetchResult::UnexpectedResponse;
                }
                for attribute in attributes {
                    match attribute {
                        AttributeValue::BodySection {
                            section: None,
                            data: Some(bytes),
                            index: None,
                        } if fetched_body.is_none() => {
                            fetched_body = Some(bytes.to_vec());
                        }
                        AttributeValue::Uid(_) | AttributeValue::Flags(_) => {}
                        _ => break 'responses FetchResult::UnexpectedResponse,
                    }
                }
            }
            Response::Done { tag, status, .. } => {
                if tag != &fetch_tag {
                    break FetchResult::WrongTag;
                }
                if *status != Status::Ok {
                    break FetchResult::Rejected;
                }
                break FetchResult::Ok;
            }
            _ => break FetchResult::UnexpectedResponse,
        }
    };
    assert_eq!(
        fetched_body.as_deref(),
        Some(STARTTLS_FETCH_SOURCE),
        "the complete body remains provisional until tagged OK"
    );
    if fetch_result == FetchResult::Ok {
        session.logout().await.expect("logout over STARTTLS");
    } else {
        drop(session);
    }

    server
        .await
        .expect("synthetic STARTTLS session server task")
        .expect("synthetic STARTTLS session protocol");
    fetch_result
}

#[tokio::test]
async fn candidate_completes_starttls_authenticated_readonly_uid_fetch_session() {
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        exercise_starttls_authenticated_uid_fetch(FetchCompletion::Ok),
    )
    .await
    .expect("STARTTLS UID FETCH session must complete");
    assert_eq!(result, FetchResult::Ok);
}

#[tokio::test]
async fn candidate_does_not_accept_failed_or_incomplete_starttls_uid_fetch() {
    for (completion, expected) in [
        (FetchCompletion::No, FetchResult::Rejected),
        (FetchCompletion::Bad, FetchResult::Rejected),
        (FetchCompletion::WrongTag, FetchResult::WrongTag),
        (FetchCompletion::Missing, FetchResult::MissingCompletion),
    ] {
        let actual = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            exercise_starttls_authenticated_uid_fetch(completion),
        )
        .await
        .expect("failed STARTTLS UID FETCH session must terminate");
        assert_eq!(actual, expected, "{completion:?}");
    }
}

#[tokio::test]
async fn candidate_stops_without_authentication_when_starttls_is_refused() {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind synthetic STARTTLS refusal server");
    let address = listener
        .local_addr()
        .expect("read synthetic STARTTLS refusal address");
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await?;
        let mut stream = BufReader::new(stream);
        stream
            .get_mut()
            .write_all(b"* OK synthetic IMAP server ready\r\n")
            .await?;
        read_command(&mut stream, "A0001 STARTTLS\r\n").await;
        stream
            .get_mut()
            .write_all(b"A0001 NO TLS unavailable\r\n")
            .await?;
        let mut after_refusal = Vec::new();
        stream.read_to_end(&mut after_refusal).await?;
        Ok::<_, std::io::Error>(after_refusal)
    });

    let stream = TcpStream::connect(address)
        .await
        .expect("connect to STARTTLS refusal server");
    let mut client = Client::new(stream);
    client
        .read_response()
        .await
        .expect("read plaintext greeting")
        .expect("STARTTLS refusal server greeting must be present");
    assert!(
        client
            .run_command_and_check_ok("STARTTLS", None)
            .await
            .is_err(),
        "STARTTLS refusal must stop the connection upgrade"
    );
    drop(client);
    assert!(
        server
            .await
            .expect("synthetic STARTTLS refusal server task")
            .expect("read bytes after STARTTLS refusal")
            .is_empty(),
        "authentication must not be sent after STARTTLS refusal"
    );
}

#[tokio::test]
async fn idle_cancellation_sends_done_and_restores_selected_session() {
    let (stream, server) = start_idle_server(true).await;
    let mut client = Client::new(stream);
    client
        .read_response()
        .await
        .expect("read greeting")
        .expect("server greeting must be present");
    let mut session = client
        .login("synthetic@example.invalid", "SYNTHETIC-PASSWORD")
        .await
        .map_err(|(error, _client)| error)
        .expect("authenticate against synthetic server");

    let capabilities = session.capabilities().await.expect("read capabilities");
    assert!(capabilities.has(&Capability::Atom("IDLE".to_string())));
    session.select("INBOX").await.expect("select INBOX");

    let mut idle = session.idle();
    idle.init().await.expect("start IDLE");
    {
        let (wait, stop_source) = idle.wait_with_timeout(std::time::Duration::from_secs(5));
        tokio::pin!(wait);
        tokio::select! {
            result = &mut wait => panic!("IDLE ended unexpectedly: {result:?}"),
            () = tokio::time::sleep(std::time::Duration::from_millis(20)) => drop(stop_source),
        }
        assert_eq!(
            wait.as_mut().await.expect("observe IDLE interruption"),
            IdleResponse::ManualInterrupt
        );
    }
    let mut session = idle.done().await.expect("send DONE and restore session");
    session
        .noop()
        .await
        .expect("reuse selected session after IDLE");
    session.logout().await.expect("logout cleanly");

    drop(session);
    server
        .await
        .expect("synthetic IMAP server task")
        .expect("synthetic IDLE transcript");
}

#[tokio::test]
async fn ac06_starttls_xoauth2_idle_notification_and_cancellation_restore_session() {
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        let (client_config, server_config) = imap_tls_configs();
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind synthetic STARTTLS IDLE server");
        let address = listener
            .local_addr()
            .expect("read synthetic STARTTLS IDLE address");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await?;
            let mut plaintext = BufReader::new(stream);
            plaintext
                .get_mut()
                .write_all(b"* OK synthetic IMAP server ready\r\n")
                .await?;
            read_command(&mut plaintext, "A0001 STARTTLS\r\n").await;
            plaintext
                .get_mut()
                .write_all(b"A0001 OK begin TLS negotiation\r\n")
                .await?;

            let tls = TlsAcceptor::from(Arc::new(server_config))
                .accept(plaintext.into_inner())
                .await?;
            let mut encrypted = BufReader::new(tls);
            read_command(&mut encrypted, "A0001 AUTHENTICATE XOAUTH2\r\n").await;
            encrypted.get_mut().write_all(b"+ \r\n").await?;
            let mut auth_response = String::new();
            encrypted.read_line(&mut auth_response).await?;
            let decoded = base64::Engine::decode(
                &base64::engine::general_purpose::STANDARD,
                auth_response.trim(),
            )
            .expect("decode synthetic STARTTLS IDLE XOAUTH2 response");
            assert_eq!(decoded, SYNTHETIC_AUTH_RESPONSE);
            encrypted
                .get_mut()
                .write_all(b"A0001 OK authenticated\r\n")
                .await?;

            read_command(&mut encrypted, "A0002 CAPABILITY\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* CAPABILITY IMAP4rev1 IDLE\r\nA0002 OK capabilities\r\n")
                .await?;
            read_command(&mut encrypted, "A0003 EXAMINE \"INBOX\"\r\n").await;
            encrypted
                .get_mut()
                .write_all(
                    b"* 0 EXISTS\r\n* OK [UIDVALIDITY 4242] selected\r\nA0003 OK [READ-ONLY] examined\r\n",
                )
                .await?;
            read_command(&mut encrypted, "A0004 IDLE\r\n").await;
            encrypted.get_mut().write_all(b"+ idling\r\n").await?;
            encrypted.get_mut().write_all(b"* 1 EXISTS\r\n").await?;
            read_command(&mut encrypted, "DONE\r\n").await;
            encrypted.get_mut().write_all(b"* 2 EXISTS\r\n").await?;
            for exists in 3..=102 {
                encrypted
                    .get_mut()
                    .write_all(format!("* {exists} EXISTS\r\n").as_bytes())
                    .await?;
            }
            encrypted
                .get_mut()
                .write_all(b"A0004 OK IDLE terminated after notification\r\n")
                .await?;
            read_command(&mut encrypted, "A0005 IDLE\r\n").await;
            encrypted.get_mut().write_all(b"+ idling\r\n").await?;
            read_command(&mut encrypted, "DONE\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"A0005 OK IDLE terminated after cancellation\r\n")
                .await?;
            read_command(&mut encrypted, "A0006 IDLE\r\n").await;
            encrypted.get_mut().write_all(b"+ idling\r\n").await?;
            read_command(&mut encrypted, "DONE\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"A0006 OK IDLE terminated after timeout\r\n")
                .await?;
            read_command(&mut encrypted, "A0007 IDLE\r\n").await;
            encrypted.get_mut().write_all(b"+ idling\r\n").await?;
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
            encrypted
                .get_mut()
                .write_all(b"* OK synthetic keepalive\r\n")
                .await?;
            tokio::time::sleep(std::time::Duration::from_millis(400)).await;
            encrypted.get_mut().write_all(b"* 3 EXISTS\r\n").await?;
            read_command(&mut encrypted, "DONE\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"A0007 OK IDLE terminated after keepalive\r\n")
                .await?;
            read_command(&mut encrypted, "A0008 NOOP\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* 102 EXISTS\r\nA0008 OK noop complete\r\n")
                .await?;
            read_command(&mut encrypted, "A0009 UID SEARCH ALL\r\n").await;
            let uids = (1..=102)
                .map(|uid| uid.to_string())
                .collect::<Vec<_>>()
                .join(" ");
            encrypted
                .get_mut()
                .write_all(format!("* SEARCH {uids}\r\nA0009 OK search complete\r\n").as_bytes())
                .await?;
            read_command(&mut encrypted, "A0010 UID FETCH 1:102 (UID FLAGS)\r\n").await;
            for uid in (1..=102).filter(|uid| *uid != 50) {
                let flags = match uid {
                    1 => "\\Seen",
                    102 => "\\Flagged",
                    _ => "",
                };
                encrypted
                    .get_mut()
                    .write_all(
                        format!("* {uid} FETCH (UID {uid} FLAGS ({flags}))\r\n").as_bytes(),
                    )
                    .await?;
            }
            encrypted
                .get_mut()
                .write_all(b"A0010 OK flags reconciled\r\n")
                .await?;
            read_command(&mut encrypted, "A0011 UID SEARCH ALL\r\n").await;
            let current_uids = (1..=102)
                .filter(|uid| *uid != 50)
                .map(|uid| uid.to_string())
                .collect::<Vec<_>>()
                .join(" ");
            encrypted
                .get_mut()
                .write_all(
                    format!("* SEARCH {current_uids}\r\nA0011 OK current UID set\r\n").as_bytes(),
                )
                .await?;
            read_command(&mut encrypted, "A0012 UID FETCH 1:102 (UID FLAGS)\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"A0012 NO temporary flags fetch failure\r\n")
                .await?;
            read_command(&mut encrypted, "A0013 NOOP\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"A0013 OK session remains usable\r\n")
                .await?;
            read_command(&mut encrypted, "A0014 UID FETCH 1:102 (UID FLAGS)\r\n").await;
            for uid in (1..=102).filter(|uid| *uid != 50) {
                let flags = match uid {
                    1 => "\\Seen",
                    102 => "\\Flagged",
                    _ => "",
                };
                encrypted
                    .get_mut()
                    .write_all(
                        format!("* {uid} FETCH (UID {uid} FLAGS ({flags}))\r\n").as_bytes(),
                    )
                    .await?;
            }
            encrypted
                .get_mut()
                .write_all(b"A0014 OK raw flags fetch complete\r\n")
                .await?;
            read_command(&mut encrypted, "A0015 UID FETCH 1:102 (UID FLAGS)\r\n").await;
            encrypted
                .get_mut()
                .write_all(
                    b"* 1 FETCH (UID 1 FLAGS (\\Seen))\r\nA0015 NO raw flags fetch rejected\r\n",
                )
                .await?;
            read_command(&mut encrypted, "A0016 NOOP\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"A0016 OK session remains synchronized\r\n")
                .await?;
            read_command(&mut encrypted, "A0017 EXAMINE \"INBOX\"\r\n").await;
            encrypted
                .get_mut()
                .write_all(
                    b"* 1 EXISTS\r\n* OK [UIDVALIDITY 4243] mailbox epoch changed\r\n* OK [UIDNEXT 51] new epoch\r\nA0017 OK [READ-ONLY] re-examined\r\n",
                )
                .await?;
            read_command(&mut encrypted, "A0018 UID SEARCH ALL\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* SEARCH 50\r\nA0018 OK new epoch UID set\r\n")
                .await?;
            read_command(&mut encrypted, "A0019 UID FETCH 50 (UID FLAGS)\r\n").await;
            encrypted
                .get_mut()
                .write_all(
                    b"* 1 FETCH (UID 50 FLAGS (\\Flagged))\r\nA0019 OK new epoch flags\r\n",
                )
                .await?;
            read_command(&mut encrypted, "A0020 UID SEARCH ALL\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* SEARCH 49 50\r\nA0020 NO temporary UID search failure\r\n")
                .await?;
            read_command(&mut encrypted, "A0021 UID SEARCH ALL\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* SEARCH 50\r\nA0021 NO raw UID search failure\r\n")
                .await?;
            read_command(&mut encrypted, "A0022 UID SEARCH ALL\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* SEARCH 49 50\r\nA0022 BAD invalid UID search\r\n")
                .await?;
            read_command(&mut encrypted, "A0023 UID SEARCH ALL\r\n").await;
            encrypted
                .get_mut()
                .write_all(
                    b"* SEARCH 49 50\r\nA9999 OK unrelated completion\r\nA0023 BAD invalid search\r\n",
                )
                .await?;
            read_command(&mut encrypted, "A0024 UID SEARCH ALL\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* SEARCH 50\r\nA0024 OK UID search complete\r\n")
                .await?;
            read_command(&mut encrypted, "A0025 UID SEARCH ALL\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* SEARCH 50 50\r\nA0025 OK duplicate UID response\r\n")
                .await?;
            read_command(&mut encrypted, "A0026 UID SEARCH ALL\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* SEARCH 0 50\r\nA0026 OK invalid UID response\r\n")
                .await?;
            read_command(&mut encrypted, "A0027 UID FETCH 50 (UID FLAGS)\r\n").await;
            encrypted
                .get_mut()
                .write_all(b"* 1 FETCH (UID 50 FLAGS (\\Flagged))\r\n")
                .await?;
            encrypted.get_mut().shutdown().await?;
            Ok::<_, std::io::Error>(())
        });

        let stream = TcpStream::connect(address)
            .await
            .expect("connect to synthetic STARTTLS IDLE server");
        let mut client = Client::new(stream);
        client
            .read_response()
            .await
            .expect("read plaintext greeting")
            .expect("STARTTLS IDLE server greeting must be present");
        client
            .run_command_and_check_ok("STARTTLS", None)
            .await
            .expect("require STARTTLS before authentication");

        let tls = upgrade_candidate_tls(client.into_inner(), client_config)
            .await
            .expect("verify and upgrade STARTTLS connection");
        let client = Client::new(tls);
        let mut session = client
            .authenticate("XOAUTH2", SyntheticXoauth2)
            .await
            .map_err(|(error, _client)| error)
            .expect("authenticate over verified STARTTLS");
        let capabilities = session
            .capabilities()
            .await
            .expect("read capabilities over STARTTLS");
        assert!(capabilities.has(&Capability::Atom("IDLE".to_string())));
        let mailbox = session
            .examine("INBOX")
            .await
            .expect("examine INBOX before IDLE");
        assert_eq!(mailbox.uid_validity, Some(4242));

        let mut idle = session.idle();
        idle.init().await.expect("start IDLE over STARTTLS");
        let (wait, _stop_source) = idle.wait_with_timeout(std::time::Duration::from_secs(2));
        match wait.await.expect("receive IDLE mailbox update") {
            IdleResponse::NewData(response) => assert_eq!(
                response.parsed(),
                &Response::MailboxData(MailboxDatum::Exists(1))
            ),
            other => panic!("expected IDLE EXISTS notification, got {other:?}"),
        }
        let session = idle
            .done()
            .await
            .expect("send DONE after IDLE mailbox update");
        let raced_notification = tokio::time::timeout(
            std::time::Duration::from_secs(1),
            session.unsolicited_responses.recv(),
        )
        .await
        .expect("receive notification delivered during DONE completion")
        .expect("unsolicited response channel remains open");
        assert_eq!(raced_notification, UnsolicitedResponse::Exists(2));
        for exists in 3..=101 {
            let notification = tokio::time::timeout(
                std::time::Duration::from_secs(1),
                session.unsolicited_responses.recv(),
            )
            .await
            .expect("receive queued IDLE notification")
            .expect("unsolicited response channel remains open");
            assert_eq!(notification, UnsolicitedResponse::Exists(exists));
        }
        assert!(
            session.unsolicited_responses.try_recv().is_err(),
            "the bounded notification queue cannot retain the 101st response"
        );
        let mut idle = session.idle();
        idle.init().await.expect("restart IDLE over STARTTLS");
        {
            let (wait, stop_source) = idle.wait_with_timeout(std::time::Duration::from_secs(2));
            tokio::pin!(wait);
            tokio::select! {
                result = &mut wait => panic!("IDLE ended unexpectedly: {result:?}"),
                () = tokio::time::sleep(std::time::Duration::from_millis(20)) => drop(stop_source),
            }
            assert_eq!(
                wait.as_mut().await.expect("observe IDLE interruption"),
                IdleResponse::ManualInterrupt
            );
        }
        let session = idle.done().await.expect("send DONE and restore session");
        let mut idle = session.idle();
        idle.init().await.expect("start IDLE for timeout check");
        let (wait, _stop_source) = idle.wait_with_timeout(std::time::Duration::from_millis(50));
        assert_eq!(
            wait.await.expect("observe IDLE timeout"),
            IdleResponse::Timeout
        );
        let session = idle.done().await.expect("send DONE after IDLE timeout");
        let mut idle = session.idle();
        idle.init().await.expect("start IDLE for keepalive check");
        let (wait, _stop_source) = idle.wait_with_timeout(std::time::Duration::from_millis(500));
        match wait.await.expect("receive update after IDLE keepalive") {
            IdleResponse::NewData(response) => assert_eq!(
                response.parsed(),
                &Response::MailboxData(MailboxDatum::Exists(3))
            ),
            other => panic!("expected EXISTS after keepalive, got {other:?}"),
        }
        let mut session = idle.done().await.expect("send DONE after keepalive update");
        session
            .noop()
            .await
            .expect("reuse selected session after IDLE");
        assert_eq!(
            session
                .unsolicited_responses
                .recv()
                .await
                .expect("NOOP resynchronization response remains queued"),
            UnsolicitedResponse::Exists(102)
        );
        let uids = session
            .uid_search("ALL")
            .await
            .expect("reconcile the full UID set after notification overflow");
        assert_eq!(uids.len(), 102);
        assert!((1..=102).all(|uid| uids.contains(&uid)));
        let mut flags = vec![None; 103];
        let mut responses = session
            .uid_fetch("1:102", "(UID FLAGS)")
            .await
            .expect("fetch current flags for the full UID set");
        let mut fetched = 0;
        while let Some(response) = responses.next().await {
            let response = response.expect("parse current UID FLAGS response");
            let uid = response.uid.expect("server returns requested UID");
            assert!((1..=102).contains(&uid));
            assert!(flags[uid as usize].is_none(), "duplicate UID {uid}");
            let response_flags: Vec<_> = response.flags().collect();
            flags[uid as usize] = Some((
                response_flags.contains(&Flag::Seen),
                response_flags.contains(&Flag::Flagged),
            ));
            fetched += 1;
        }
        assert_eq!(fetched, 101);
        assert_eq!(flags[1], Some((true, false)));
        assert_eq!(flags[2], Some((false, false)));
        assert_eq!(flags[50], None, "expunged UID has no FLAGS response");
        assert_eq!(flags[102], Some((false, true)));
        drop(responses);
        let current_uids = session
            .uid_search("ALL")
            .await
            .expect("reconcile the UID set after a FETCH-time expunge");
        assert_eq!(current_uids.len(), 101);
        assert!(!current_uids.contains(&50));
        let mut rejected_fetch = session
            .uid_fetch("1:102", "(UID FLAGS)")
            .await
            .expect("UID FETCH API starts even when server will reject the command");
        assert!(
            rejected_fetch.next().await.is_none(),
            "tagged NO is hidden as an empty FETCH stream"
        );
        drop(rejected_fetch);
        session
            .noop()
            .await
            .expect("session remains synchronized after rejected FETCH");
        let fetch_tag = session
            .run_command("UID FETCH 1:102 (UID FLAGS)")
            .await
            .expect("start raw FLAGS FETCH with an inspectable tagged completion");
        let mut raw_flags = vec![None; 103];
        let raw_fetch_succeeded = loop {
            let response = session
                .read_response()
                .await
                .expect("read raw FLAGS FETCH response")
                .expect("server returns tagged completion");
            match response.parsed() {
                Response::Fetch(_, attributes) => {
                    let mut uid = None;
                    let mut flags_present = false;
                    let mut has_seen = false;
                    let mut has_flagged = false;
                    for attribute in attributes {
                        match attribute {
                            AttributeValue::Uid(value) if uid.replace(*value).is_none() => {}
                            AttributeValue::Flags(values) if !flags_present => {
                                flags_present = true;
                                has_seen = values.iter().any(|value| value == "\\Seen");
                                has_flagged = values.iter().any(|value| value == "\\Flagged");
                            }
                            _ => panic!("unexpected or duplicate raw FLAGS FETCH attribute"),
                        }
                    }
                    let uid = uid.expect("raw FLAGS response includes UID");
                    assert!((1..=102).contains(&uid));
                    assert!(flags_present, "raw FLAGS response includes FLAGS");
                    assert!(raw_flags[uid as usize].is_none(), "duplicate UID {uid}");
                    raw_flags[uid as usize] = Some((has_seen, has_flagged));
                }
                Response::Done { tag, status, .. } => {
                    assert_eq!(tag, &fetch_tag);
                    break status == &Status::Ok;
                }
                other => panic!("unexpected raw FLAGS FETCH response: {other:?}"),
            }
        };
        assert!(raw_fetch_succeeded);
        assert_eq!(raw_flags[1], Some((true, false)));
        assert_eq!(raw_flags[2], Some((false, false)));
        assert_eq!(raw_flags[102], Some((false, true)));
        assert_eq!(
            raw_flags.iter().skip(1).take(102).filter(|flags| flags.is_some()).count(),
            101
        );
        assert_eq!(raw_flags[50], None);
        let rejected_tag = session
            .run_command("UID FETCH 1:102 (UID FLAGS)")
            .await
            .expect("start raw FLAGS FETCH expected to be rejected");
        let mut partial_uids = Vec::new();
        let rejected_status = loop {
            let response = session
                .read_response()
                .await
                .expect("read rejected raw FLAGS FETCH response")
                .expect("server returns tagged rejection");
            match response.parsed() {
                Response::Fetch(_, attributes) => {
                    let uid = attributes.iter().find_map(|attribute| match attribute {
                        AttributeValue::Uid(uid) => Some(*uid),
                        _ => None,
                    });
                    partial_uids.push(uid.expect("partial FETCH response includes UID"));
                }
                Response::Done { tag, status, .. } => {
                    assert_eq!(tag, &rejected_tag);
                    break status == &Status::No;
                }
                other => panic!("unexpected response before rejected FETCH completion: {other:?}"),
            }
        };
        assert!(rejected_status);
        assert_eq!(partial_uids, [1]);
        assert_ne!(partial_uids.len(), raw_flags.len() - 1);
        session
            .noop()
            .await
            .expect("raw rejected FETCH leaves session synchronized");
        let mailbox = session
            .examine("INBOX")
            .await
            .expect("re-examine mailbox to detect a changed UIDVALIDITY");
        assert_eq!(mailbox.uid_validity, Some(4243));
        let new_epoch_uids = session
            .uid_search("ALL")
            .await
            .expect("fetch UID set in the changed mailbox epoch");
        assert_eq!(new_epoch_uids.len(), 1);
        assert!(new_epoch_uids.contains(&50));
        let new_epoch_tag = session
            .run_command("UID FETCH 50 (UID FLAGS)")
            .await
            .expect("fetch UID 50 only after observing the new UIDVALIDITY");
        let mut new_epoch_flags = None;
        let new_epoch_fetch_succeeded = loop {
            let response = session
                .read_response()
                .await
                .expect("read new epoch FLAGS response")
                .expect("server returns new epoch tagged completion");
            match response.parsed() {
                Response::Fetch(_, attributes) => {
                    let uid = attributes.iter().find_map(|attribute| match attribute {
                        AttributeValue::Uid(uid) => Some(*uid),
                        _ => None,
                    });
                    assert_eq!(uid, Some(50));
                    let flags = attributes.iter().find_map(|attribute| match attribute {
                        AttributeValue::Flags(flags) => Some(flags),
                        _ => None,
                    });
                    let flags = flags.expect("new epoch response includes FLAGS");
                    new_epoch_flags = Some((
                        flags.iter().any(|flag| flag == "\\Seen"),
                        flags.iter().any(|flag| flag == "\\Flagged"),
                    ));
                }
                Response::Done { tag, status, .. } => {
                    assert_eq!(tag, &new_epoch_tag);
                    break status == &Status::Ok;
                }
                other => panic!("unexpected new epoch response: {other:?}"),
            }
        };
        assert!(new_epoch_fetch_succeeded);
        assert_eq!(new_epoch_flags, Some((false, true)));
        let partial_uids = session
            .uid_search("ALL")
            .await
            .expect("high-level search returns even after tagged NO");
        assert_eq!(partial_uids, [49, 50].into_iter().collect());
        assert_eq!(
            raw_uid_search(&mut session).await.expect("raw UID SEARCH command"),
            RawUidSearchResult::Rejected {
                status: SearchRejection::No,
                uids: [50].into_iter().collect(),
            }
        );
        assert_eq!(
            raw_uid_search(&mut session).await.expect("raw UID SEARCH command"),
            RawUidSearchResult::Rejected {
                status: SearchRejection::Bad,
                uids: [49, 50].into_iter().collect(),
            }
        );
        assert_eq!(
            raw_uid_search(&mut session).await.expect("raw UID SEARCH command"),
            RawUidSearchResult::WrongTag([49, 50].into_iter().collect())
        );
        let complete_uids = match raw_uid_search(&mut session)
            .await
            .expect("raw UID SEARCH command")
        {
            RawUidSearchResult::Complete(uids) => uids,
            other => panic!("expected complete UID SEARCH result, got {other:?}"),
        };
        assert_eq!(complete_uids, [50].into_iter().collect());
        assert_eq!(
            raw_uid_search(&mut session).await.expect("raw UID SEARCH command"),
            RawUidSearchResult::DuplicateUids([50].into_iter().collect())
        );
        assert_eq!(
            raw_uid_search(&mut session).await.expect("raw UID SEARCH command"),
            RawUidSearchResult::InvalidUids([0, 50].into_iter().collect())
        );
        let mut incomplete_fetch = session
            .uid_fetch("50", "(UID FLAGS)")
            .await
            .expect("high-level FETCH starts before completion is lost");
        let partial_response = incomplete_fetch
            .next()
            .await
            .expect("partial FETCH record is surfaced before EOF")
            .expect("partial FETCH record parses");
        assert_eq!(partial_response.uid, Some(50));
        assert!(
            incomplete_fetch.next().await.is_none(),
            "high-level FETCH silently ends without a tagged completion"
        );
        drop(incomplete_fetch);
        drop(session);

        server
            .await
            .expect("synthetic STARTTLS IDLE server task")
            .expect("synthetic STARTTLS IDLE protocol");
    })
    .await
    .expect("STARTTLS IDLE cancellation flow must finish");
}

#[tokio::test]
async fn client_polls_when_server_does_not_advertise_idle() {
    let (stream, server) = start_idle_server(false).await;
    let mut client = Client::new(stream);
    client
        .read_response()
        .await
        .expect("read greeting")
        .expect("server greeting must be present");
    let mut session = client
        .login("synthetic@example.invalid", "SYNTHETIC-PASSWORD")
        .await
        .map_err(|(error, _client)| error)
        .expect("authenticate against synthetic server");

    let capabilities = session.capabilities().await.expect("read capabilities");
    assert!(!capabilities.has(&Capability::Atom("IDLE".to_string())));
    session.noop().await.expect("poll with NOOP fallback");
    session.logout().await.expect("logout cleanly");

    drop(session);
    server
        .await
        .expect("synthetic IMAP server task")
        .expect("synthetic polling transcript");
}

#[tokio::test]
async fn ac08_uid_search_partial_response_before_eof_is_not_a_complete_result() {
    let (stream, server_stream) = tokio::io::duplex(1024);
    let high_level_server = tokio::spawn(async move {
        let mut server = BufReader::new(server_stream);
        server
            .get_mut()
            .write_all(b"* OK synthetic IMAP server ready\r\n")
            .await?;
        read_command(
            &mut server,
            "A0001 LOGIN \"synthetic@example.invalid\" \"SYNTHETIC-PASSWORD\"\r\n",
        )
        .await;
        server
            .get_mut()
            .write_all(b"A0001 OK authenticated\r\n")
            .await?;
        read_command(&mut server, "A0002 UID SEARCH ALL\r\n").await;
        server.get_mut().write_all(b"* SEARCH 49 50\r\n").await?;
        server.get_mut().shutdown().await
    });
    let mut client = Client::new(stream);
    client
        .read_response()
        .await
        .expect("read high-level search greeting")
        .expect("search server greeting is present");
    let mut session = client
        .login("synthetic@example.invalid", "SYNTHETIC-PASSWORD")
        .await
        .map_err(|(error, _client)| error)
        .expect("authenticate for high-level search test");
    let high_level_uids = session
        .uid_search("ALL")
        .await
        .expect("high-level search returns partial result despite EOF");
    assert_eq!(high_level_uids, [49, 50].into_iter().collect());
    drop(session);
    high_level_server
        .await
        .expect("high-level UID SEARCH server task")
        .expect("high-level UID SEARCH transcript");

    let (stream, server_stream) = tokio::io::duplex(1024);
    let raw_server = tokio::spawn(async move {
        let mut server = BufReader::new(server_stream);
        server
            .get_mut()
            .write_all(b"* OK synthetic IMAP server ready\r\n")
            .await?;
        read_command(
            &mut server,
            "A0001 LOGIN \"synthetic@example.invalid\" \"SYNTHETIC-PASSWORD\"\r\n",
        )
        .await;
        server
            .get_mut()
            .write_all(b"A0001 OK authenticated\r\n")
            .await?;
        read_command(&mut server, "A0002 UID SEARCH ALL\r\n").await;
        server.get_mut().write_all(b"* SEARCH 49 50\r\n").await?;
        server.get_mut().shutdown().await
    });
    let mut client = Client::new(stream);
    client
        .read_response()
        .await
        .expect("read raw search greeting")
        .expect("raw search server greeting is present");
    let mut session = client
        .login("synthetic@example.invalid", "SYNTHETIC-PASSWORD")
        .await
        .map_err(|(error, _client)| error)
        .expect("authenticate for raw search test");
    assert_eq!(
        raw_uid_search(&mut session)
            .await
            .expect("raw UID SEARCH command"),
        RawUidSearchResult::MissingCompletion([49, 50].into_iter().collect())
    );
    raw_server
        .await
        .expect("raw UID SEARCH server task")
        .expect("raw UID SEARCH transcript");
}
