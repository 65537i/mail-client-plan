use std::{io::ErrorKind, sync::Arc};

use async_imap::extensions::idle::IdleResponse;
use async_imap::types::{Capability, Flag};
use async_imap::{Authenticator, Client};
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
