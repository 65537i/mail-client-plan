use std::{io, net::SocketAddr, time::Duration};

use lettre::{
    AsyncSmtpTransport, AsyncTransport, Tokio1Executor,
    address::{Address, Envelope},
    transport::smtp::response::Response,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    task::JoinHandle,
};

#[path = "smtp_tls.rs"]
mod smtp_tls;

struct SmtpTranscript {
    commands: Vec<String>,
    message: Vec<u8>,
}

enum FinalReply {
    Complete(&'static [u8]),
    Disconnect(&'static [u8]),
}

async fn read_command(
    stream: &mut BufReader<TcpStream>,
    transcript: &mut SmtpTranscript,
) -> io::Result<String> {
    let mut command = String::new();
    if stream.read_line(&mut command).await? == 0 {
        return Err(io::Error::new(
            io::ErrorKind::UnexpectedEof,
            "SMTP client disconnected before the expected command",
        ));
    }
    transcript.commands.push(command.clone());
    Ok(command)
}

async fn start_smtp_sink(
    recipient_reply: &'static [u8],
    final_reply: FinalReply,
) -> (SocketAddr, JoinHandle<io::Result<SmtpTranscript>>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind loopback SMTP sink");
    let address = listener.local_addr().expect("read SMTP sink address");

    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await?;
        let mut stream = BufReader::new(stream);
        let mut transcript = SmtpTranscript {
            commands: Vec::new(),
            message: Vec::new(),
        };
        stream
            .get_mut()
            .write_all(b"220 synthetic SMTP sink ready\r\n")
            .await?;

        let command = read_command(&mut stream, &mut transcript).await?;
        assert!(command.starts_with("EHLO "));
        stream
            .get_mut()
            .write_all(b"250-synthetic.invalid\r\n250 8BITMIME\r\n")
            .await?;

        assert_eq!(
            read_command(&mut stream, &mut transcript).await?,
            "MAIL FROM:<sender@example.invalid>\r\n"
        );
        stream
            .get_mut()
            .write_all(b"250 2.1.0 sender accepted\r\n")
            .await?;

        assert_eq!(
            read_command(&mut stream, &mut transcript).await?,
            "RCPT TO:<recipient@example.invalid>\r\n"
        );
        stream.get_mut().write_all(recipient_reply).await?;
        if !recipient_reply.starts_with(b"250") {
            assert_eq!(
                read_command(&mut stream, &mut transcript).await?,
                "QUIT\r\n"
            );
            stream
                .get_mut()
                .write_all(b"221 2.0.0 closing connection\r\n")
                .await?;
            return Ok(transcript);
        }

        assert_eq!(
            read_command(&mut stream, &mut transcript).await?,
            "DATA\r\n"
        );
        stream
            .get_mut()
            .write_all(b"354 end with <CRLF>.<CRLF>\r\n")
            .await?;
        loop {
            let mut line = Vec::new();
            if stream.read_until(b'\n', &mut line).await? == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "SMTP client disconnected before the DATA terminator",
                ));
            }
            if line == b".\r\n" {
                break;
            }
            transcript.message.extend_from_slice(&line);
        }
        match final_reply {
            FinalReply::Complete(reply) => stream.get_mut().write_all(reply).await?,
            FinalReply::Disconnect(partial_reply) => {
                stream.get_mut().write_all(partial_reply).await?;
                stream.get_mut().shutdown().await?;
                drop(stream);
                assert!(
                    tokio::time::timeout(Duration::from_millis(250), listener.accept())
                        .await
                        .is_err(),
                    "an ambiguous submission must not cause an automatic reconnect"
                );
                return Ok(transcript);
            }
        }

        assert_eq!(
            read_command(&mut stream, &mut transcript).await?,
            "QUIT\r\n"
        );
        stream
            .get_mut()
            .write_all(b"221 2.0.0 closing connection\r\n")
            .await?;
        Ok(transcript)
    });

    (address, server)
}

fn transport(address: SocketAddr) -> AsyncSmtpTransport<Tokio1Executor> {
    AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous("127.0.0.1")
        .port(address.port())
        .build()
}

fn envelope() -> Envelope {
    let sender: Address = "sender@example.invalid"
        .parse()
        .expect("parse synthetic sender");
    let recipient: Address = "recipient@example.invalid"
        .parse()
        .expect("parse synthetic recipient");
    Envelope::new(Some(sender), vec![recipient]).expect("build synthetic envelope")
}

const SYNTHETIC_MESSAGE: &[u8] = b"From: sender@example.invalid\r\nTo: recipient@example.invalid\r\nSubject: synthetic SMTP PoC\r\n\r\nSynthetic body only.\r\n";

async fn send_with_timeout(
    transport: &AsyncSmtpTransport<Tokio1Executor>,
) -> Result<Response, lettre::transport::smtp::Error> {
    tokio::time::timeout(
        Duration::from_secs(3),
        transport.send_raw(&envelope(), SYNTHETIC_MESSAGE),
    )
    .await
    .expect("SMTP candidate operation must not hang")
}

#[tokio::test]
async fn candidate_returns_final_positive_smtp_acceptance() {
    let (address, server) = start_smtp_sink(
        b"250 2.1.5 recipient accepted\r\n",
        FinalReply::Complete(b"250 2.0.0 queued\r\n"),
    )
    .await;
    let response = send_with_timeout(&transport(address))
        .await
        .expect("complete SMTP transaction");

    assert!(response.is_positive());
    assert!(response.has_code(250));
    assert_eq!(response.message().collect::<Vec<_>>(), ["2.0.0 queued"]);

    let transcript = server
        .await
        .expect("synthetic SMTP server task")
        .expect("synthetic SMTP transcript");
    assert!(
        transcript
            .commands
            .iter()
            .any(|command| command == "DATA\r\n")
    );
    assert!(
        String::from_utf8_lossy(&transcript.message).contains("Synthetic body only."),
        "the sink should receive only the synthetic message"
    );
}

#[tokio::test]
async fn candidate_preserves_final_negative_smtp_status() {
    let (address, server) = start_smtp_sink(
        b"250 2.1.5 recipient accepted\r\n",
        FinalReply::Complete(b"550 5.7.1 rejected\r\n"),
    )
    .await;
    let error = send_with_timeout(&transport(address))
        .await
        .expect_err("final SMTP rejection must not look accepted");

    assert!(error.is_permanent());
    assert_eq!(
        error.status().map(|status| status.to_string()).as_deref(),
        Some("550")
    );

    let transcript = server
        .await
        .expect("synthetic SMTP server task")
        .expect("synthetic SMTP transcript");
    assert!(
        transcript
            .commands
            .iter()
            .any(|command| command == "DATA\r\n")
    );
    assert!(
        String::from_utf8_lossy(&transcript.message).contains("Synthetic body only."),
        "the final status is returned after the sink receives the message body"
    );
}

#[tokio::test]
async fn candidate_stops_before_data_when_recipient_is_rejected() {
    let (address, server) = start_smtp_sink(
        b"550 5.1.1 recipient rejected\r\n",
        FinalReply::Complete(b"250 2.0.0 unused\r\n"),
    )
    .await;
    let error = send_with_timeout(&transport(address))
        .await
        .expect_err("recipient refusal must fail the transaction");

    assert!(error.is_permanent());
    assert_eq!(
        error.status().map(|status| status.to_string()).as_deref(),
        Some("550")
    );

    let transcript = server
        .await
        .expect("synthetic SMTP server task")
        .expect("synthetic SMTP transcript");
    assert!(
        !transcript
            .commands
            .iter()
            .any(|command| command == "DATA\r\n")
    );
    assert!(transcript.message.is_empty());
}

async fn assert_ambiguous_submission_is_not_retried(partial_reply: &'static [u8]) {
    let (address, server) = start_smtp_sink(
        b"250 2.1.5 recipient accepted\r\n",
        FinalReply::Disconnect(partial_reply),
    )
    .await;
    let error = send_with_timeout(&transport(address))
        .await
        .expect_err("missing complete final reply must not look accepted");
    assert!(
        error.status().is_none(),
        "an incomplete reply is not a definitive SMTP rejection"
    );
    assert!(!error.is_permanent());
    assert!(!error.is_transient());

    let transcript = tokio::time::timeout(Duration::from_secs(3), server)
        .await
        .expect("disconnect fixture must finish")
        .expect("synthetic SMTP server task")
        .expect("synthetic SMTP transcript");
    // lettre appends CRLF before the DATA terminator even for CRLF-ended input.
    assert_eq!(transcript.message, [SYNTHETIC_MESSAGE, b"\r\n"].concat());
    assert_eq!(
        transcript
            .commands
            .iter()
            .filter(|command| command.as_str() == "DATA\r\n")
            .count(),
        1,
        "the sink received exactly one submission"
    );
}

#[tokio::test]
async fn ac_13_candidate_does_not_retry_after_lost_final_response() {
    assert_ambiguous_submission_is_not_retried(b"").await;
}

#[tokio::test]
async fn ac_13_candidate_does_not_accept_or_retry_a_truncated_final_response() {
    assert_ambiguous_submission_is_not_retried(b"250 2.0.0 queued").await;
}
