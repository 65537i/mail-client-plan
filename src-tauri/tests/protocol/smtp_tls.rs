use std::{io, net::SocketAddr, sync::Arc, time::Duration};

use lettre::{
    AsyncSmtpTransport, Tokio1Executor,
    transport::smtp::{
        authentication::{Credentials, Mechanism},
        client::{Certificate, CertificateStore, Tls, TlsParameters},
    },
};
use rcgen::{CertifiedKey, KeyPair, generate_simple_self_signed};
use rustls::{
    ServerConfig,
    pki_types::{PrivateKeyDer, PrivatePkcs8KeyDer},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncWrite, AsyncWriteExt, BufReader},
    net::TcpListener,
    task::JoinHandle,
};
use tokio_rustls::TlsAcceptor;

#[derive(Clone, Copy)]
enum Mode {
    Implicit,
    Starttls,
    RefuseStarttls,
    MissingStarttls,
}

#[derive(Default)]
struct Transcript {
    plaintext: Vec<String>,
    encrypted: Vec<String>,
    handshake_completed: bool,
}

async fn command<T: AsyncRead + Unpin>(stream: &mut BufReader<T>) -> io::Result<String> {
    let mut line = String::new();
    if stream.read_line(&mut line).await? == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "expected SMTP command",
        ));
    }
    Ok(line)
}

async fn hello<T: AsyncRead + AsyncWrite + Unpin>(
    stream: &mut BufReader<T>,
    commands: &mut Vec<String>,
) -> io::Result<()> {
    let line = command(stream).await?;
    assert!(line.starts_with("EHLO "));
    commands.push(line);
    Ok(())
}

async fn start_server(
    certificate: &CertifiedKey<KeyPair>,
    mode: Mode,
) -> (SocketAddr, JoinHandle<io::Result<Transcript>>) {
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(
        certificate.signing_key.serialize_der(),
    ));
    let config = ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![certificate.cert.der().clone()], key)
        .expect("configure synthetic SMTP TLS server");
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind SMTP TLS sink");
    let address = listener.local_addr().expect("SMTP TLS sink address");
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await?;
        let mut stream = BufReader::new(stream);
        let mut transcript = Transcript::default();
        if !matches!(mode, Mode::Implicit) {
            stream
                .get_mut()
                .write_all(b"220 synthetic SMTP ready\r\n")
                .await?;
            hello(&mut stream, &mut transcript.plaintext).await?;
            let capabilities: &[u8] = if matches!(mode, Mode::MissingStarttls) {
                b"250-synthetic.invalid\r\n250 AUTH PLAIN\r\n"
            } else {
                b"250-synthetic.invalid\r\n250-STARTTLS\r\n250 AUTH PLAIN\r\n"
            };
            stream.get_mut().write_all(capabilities).await?;
            if !matches!(mode, Mode::MissingStarttls) {
                let line = command(&mut stream).await?;
                assert_eq!(line, "STARTTLS\r\n");
                transcript.plaintext.push(line);
                stream
                    .get_mut()
                    .write_all(if matches!(mode, Mode::RefuseStarttls) {
                        b"454 TLS unavailable\r\n"
                    } else {
                        b"220 begin TLS\r\n"
                    })
                    .await?;
            }
            if matches!(mode, Mode::RefuseStarttls | Mode::MissingStarttls) {
                loop {
                    let mut line = String::new();
                    if stream.read_line(&mut line).await? == 0 {
                        break;
                    }
                    let quitting = line == "QUIT\r\n";
                    transcript.plaintext.push(line);
                    if quitting {
                        stream.get_mut().write_all(b"221 closing\r\n").await?;
                        break;
                    }
                    stream.get_mut().write_all(b"530 TLS required\r\n").await?;
                }
                return Ok(transcript);
            }
        }
        let tls = match TlsAcceptor::from(Arc::new(config))
            .accept(stream.into_inner())
            .await
        {
            Ok(tls) => tls,
            Err(_) => return Ok(transcript),
        };
        transcript.handshake_completed = true;
        let mut stream = BufReader::new(tls);
        if matches!(mode, Mode::Implicit) {
            stream
                .get_mut()
                .write_all(b"220 synthetic SMTP TLS ready\r\n")
                .await?;
        }
        hello(&mut stream, &mut transcript.encrypted).await?;
        stream
            .get_mut()
            .write_all(b"250-synthetic.invalid\r\n250 AUTH PLAIN\r\n")
            .await?;
        let auth = command(&mut stream).await?;
        assert_eq!(auth, "AUTH PLAIN AHN5bnRoZXRpYwBzeW50aGV0aWM=\r\n");
        transcript.encrypted.push(auth);
        stream.get_mut().write_all(b"235 authenticated\r\n").await?;
        let noop = command(&mut stream).await?;
        assert_eq!(noop, "NOOP\r\n");
        transcript.encrypted.push(noop);
        stream.get_mut().write_all(b"250 OK\r\n").await?;
        assert_eq!(command(&mut stream).await?, "QUIT\r\n");
        stream.get_mut().write_all(b"221 closing\r\n").await?;
        Ok(transcript)
    });
    (address, server)
}

async fn check(mode: Mode, trust_certificate: bool, hostname: &str, succeeds: bool) {
    let certificate = generate_simple_self_signed(vec!["localhost".to_string()])
        .expect("generate synthetic SMTP certificate");
    let (address, server) = start_server(&certificate, mode).await;
    let mut parameters =
        TlsParameters::builder(hostname.to_string()).certificate_store(CertificateStore::None);
    if trust_certificate {
        parameters = parameters.add_root_certificate(
            Certificate::from_der(certificate.cert.der().to_vec()).expect("synthetic root"),
        );
    }
    let parameters = parameters.build_rustls().expect("SMTP rustls parameters");
    let tls = if matches!(mode, Mode::Implicit) {
        Tls::Wrapper(parameters)
    } else {
        Tls::Required(parameters)
    };
    let transport: AsyncSmtpTransport<Tokio1Executor> =
        AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous("127.0.0.1")
            .port(address.port())
            .tls(tls)
            .credentials(Credentials::new("synthetic".into(), "synthetic".into()))
            .authentication(vec![Mechanism::Plain])
            .timeout(Some(Duration::from_secs(2)))
            .build();
    let result = tokio::time::timeout(Duration::from_secs(3), transport.test_connection())
        .await
        .expect("SMTP TLS client must finish");
    if succeeds {
        assert!(result.expect("trusted SMTP TLS connection"));
    } else {
        let error = result.expect_err("TLS policy failure must not succeed");
        match mode {
            Mode::Implicit | Mode::Starttls => {
                let mut source: &(dyn std::error::Error + 'static) = &error;
                let mut rejected_certificate = false;
                loop {
                    if matches!(
                        source.downcast_ref::<rustls::Error>(),
                        Some(rustls::Error::InvalidCertificate(_))
                    ) {
                        rejected_certificate = true;
                        break;
                    }
                    let next = source
                        .downcast_ref::<io::Error>()
                        .and_then(|error| {
                            error.get_ref().map(|inner| inner as &dyn std::error::Error)
                        })
                        .or_else(|| source.source());
                    match next {
                        Some(next) => source = next,
                        None => break,
                    }
                }
                assert!(
                    rejected_certificate,
                    "expected certificate validation error: {error:?}"
                );
            }
            Mode::RefuseStarttls => assert_eq!(
                error.status().map(|status| status.to_string()).as_deref(),
                Some("454"),
            ),
            Mode::MissingStarttls => assert!(error.is_client()),
        }
    }
    drop(transport);
    let transcript = tokio::time::timeout(Duration::from_secs(3), server)
        .await
        .expect("SMTP TLS sink must finish")
        .expect("SMTP TLS sink task")
        .expect("SMTP TLS transcript");
    assert!(
        transcript
            .plaintext
            .iter()
            .all(|line| line.starts_with("EHLO ") || line == "STARTTLS\r\n" || line == "QUIT\r\n"),
        "plaintext commands must contain only negotiation or shutdown, never credentials or message data"
    );
    assert_eq!(transcript.handshake_completed, succeeds);
    if succeeds {
        assert_eq!(
            transcript
                .encrypted
                .iter()
                .filter(|line| line.starts_with("AUTH "))
                .count(),
            1
        );
    } else {
        assert!(
            transcript.encrypted.is_empty(),
            "no application data before TLS validation"
        );
    }
}

#[tokio::test]
async fn ac06_smtp_authenticates_only_after_verified_implicit_tls() {
    check(Mode::Implicit, true, "localhost", true).await;
}

#[tokio::test]
async fn ac06_smtp_authenticates_only_after_required_starttls() {
    check(Mode::Starttls, true, "localhost", true).await;
}

#[tokio::test]
async fn ac06_smtp_rejects_untrusted_implicit_tls_before_auth() {
    check(Mode::Implicit, false, "localhost", false).await;
}

#[tokio::test]
async fn ac06_smtp_rejects_untrusted_starttls_before_auth() {
    check(Mode::Starttls, false, "localhost", false).await;
}

#[tokio::test]
async fn ac06_smtp_rejects_implicit_tls_hostname_mismatch_before_auth() {
    check(Mode::Implicit, true, "wrong.example", false).await;
}

#[tokio::test]
async fn ac06_smtp_rejects_starttls_hostname_mismatch_before_auth() {
    check(Mode::Starttls, true, "wrong.example", false).await;
}

#[tokio::test]
async fn ac06_smtp_never_falls_back_after_starttls_refusal() {
    check(Mode::RefuseStarttls, true, "localhost", false).await;
}

#[tokio::test]
async fn ac06_smtp_never_falls_back_when_starttls_is_not_advertised() {
    check(Mode::MissingStarttls, true, "localhost", false).await;
}
