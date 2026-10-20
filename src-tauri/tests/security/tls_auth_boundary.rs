use std::{io::ErrorKind, sync::Arc};

use rcgen::{CertifiedKey, KeyPair, generate_simple_self_signed};
use rustls::{
    ClientConfig, RootCertStore, ServerConfig,
    pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer, ServerName},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
};
use tokio_rustls::{TlsAcceptor, TlsConnector};

const SYNTHETIC_CREDENTIAL: &[u8] = b"SYNTHETIC-AC-06-CREDENTIAL";

fn test_certificate() -> CertifiedKey<KeyPair> {
    generate_simple_self_signed(vec!["localhost".to_string()])
        .expect("generate synthetic localhost certificate")
}

fn server_config(certificate: &CertifiedKey<KeyPair>) -> ServerConfig {
    let private_key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        certificate.signing_key.serialize_der(),
    ));

    ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![certificate.cert.der().clone()], private_key)
        .expect("build local TLS server config")
}

fn client_config(roots: RootCertStore) -> ClientConfig {
    ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth()
}

async fn start_tls_server(
    config: ServerConfig,
) -> (std::net::SocketAddr, JoinHandle<std::io::Result<Vec<u8>>>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind local TLS server");
    let address = listener.local_addr().expect("read local TLS address");

    let task = tokio::spawn(async move {
        let (stream, _) = listener
            .accept()
            .await
            .expect("accept local TLS connection");
        let acceptor = TlsAcceptor::from(Arc::new(config));
        let Ok(mut tls) = acceptor.accept(stream).await else {
            return Ok(Vec::new());
        };

        let mut received = Vec::new();
        tls.read_to_end(&mut received).await?;
        Ok(received)
    });

    (address, task)
}

async fn tls_then_send_credentials(
    address: std::net::SocketAddr,
    hostname: &str,
    config: ClientConfig,
) -> Result<(), std::io::Error> {
    let stream = TcpStream::connect(address).await?;
    tls_then_send_credentials_on_stream(stream, hostname, config).await
}

async fn starttls_then_send_credentials(
    address: std::net::SocketAddr,
    hostname: &str,
    config: ClientConfig,
) -> Result<(), std::io::Error> {
    let mut stream = BufReader::new(TcpStream::connect(address).await?);
    stream.get_mut().write_all(b"STARTTLS\r\n").await?;

    let mut response = Vec::new();
    stream.read_until(b'\n', &mut response).await?;
    if !response.starts_with(b"220 ") {
        return Err(std::io::Error::new(
            ErrorKind::PermissionDenied,
            "server refused STARTTLS",
        ));
    }

    let stream = stream.into_inner();
    tls_then_send_credentials_on_stream(stream, hostname, config).await
}

async fn tls_then_send_credentials_on_stream(
    stream: TcpStream,
    hostname: &str,
    config: ClientConfig,
) -> Result<(), std::io::Error> {
    let server_name = ServerName::try_from(hostname.to_string())
        .map_err(|error| std::io::Error::new(ErrorKind::InvalidInput, error))?;
    let mut tls = TlsConnector::from(Arc::new(config))
        .connect(server_name, stream)
        .await?;

    tls.write_all(SYNTHETIC_CREDENTIAL).await?;
    tls.shutdown().await
}

async fn start_refusing_starttls_server() -> (
    std::net::SocketAddr,
    JoinHandle<std::io::Result<(Vec<u8>, Vec<u8>)>>,
) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind local STARTTLS server");
    let address = listener.local_addr().expect("read local STARTTLS address");
    let task = tokio::spawn(async move {
        let (stream, _) = listener
            .accept()
            .await
            .expect("accept local STARTTLS connection");
        let mut stream = BufReader::new(stream);
        let mut command = Vec::new();
        stream.read_until(b'\n', &mut command).await?;
        stream
            .get_mut()
            .write_all(b"454 TLS unavailable\r\n")
            .await?;
        let mut after_refusal = Vec::new();
        stream.read_to_end(&mut after_refusal).await?;
        Ok((command, after_refusal))
    });

    (address, task)
}

#[tokio::test]
async fn ac06_rejects_untrusted_certificate_before_authentication() {
    let certificate = test_certificate();
    let (address, server) = start_tls_server(server_config(&certificate)).await;
    let result =
        tls_then_send_credentials(address, "localhost", client_config(RootCertStore::empty()))
            .await;

    assert!(result.is_err(), "an untrusted certificate must fail TLS");
    assert!(
        server
            .await
            .expect("TLS server task")
            .expect("read TLS application data")
            .is_empty(),
        "credential bytes must not reach an untrusted TLS server"
    );
}

#[tokio::test]
async fn ac06_sends_no_authentication_after_starttls_refusal() {
    let (address, server) = start_refusing_starttls_server().await;
    let result =
        starttls_then_send_credentials(address, "localhost", client_config(RootCertStore::empty()))
            .await;

    assert!(
        result.is_err(),
        "a STARTTLS refusal must stop authentication"
    );
    let (command, after_refusal) = server
        .await
        .expect("STARTTLS server task")
        .expect("read STARTTLS application data");
    assert_eq!(command, b"STARTTLS\r\n");
    assert!(
        after_refusal.is_empty(),
        "authentication bytes must not follow a STARTTLS refusal"
    );
}

#[tokio::test]
async fn ac06_rejects_hostname_mismatch_before_authentication() {
    let certificate = test_certificate();
    let mut roots = RootCertStore::empty();
    roots
        .add(certificate.cert.der().clone())
        .expect("trust synthetic certificate for hostname test");
    let (address, server) = start_tls_server(server_config(&certificate)).await;
    let result = tls_then_send_credentials(address, "wrong.example", client_config(roots)).await;

    assert!(result.is_err(), "a hostname mismatch must fail TLS");
    assert!(
        server
            .await
            .expect("TLS server task")
            .expect("read TLS application data")
            .is_empty(),
        "credential bytes must not reach a hostname-mismatched TLS server"
    );
}
