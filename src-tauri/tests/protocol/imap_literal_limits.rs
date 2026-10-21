use std::{
    io,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll},
};

use async_imap::Client;
use mail_client_lib::mime_poc::MAX_RAW_BYTES;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

#[derive(Debug)]
struct HeaderOnlyProbe {
    header: Option<Vec<u8>>,
    read_regions: Arc<Mutex<Vec<usize>>>,
}

impl AsyncRead for HeaderOnlyProbe {
    fn poll_read(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        self.read_regions.lock().unwrap().push(buffer.remaining());
        if let Some(header) = self.header.take() {
            assert!(header.len() <= buffer.remaining());
            buffer.put_slice(&header);
            Poll::Ready(Ok(()))
        } else {
            Poll::Ready(Err(io::Error::other(
                "synthetic transport read budget exhausted",
            )))
        }
    }
}

impl AsyncWrite for HeaderOnlyProbe {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        _buffer: &[u8],
    ) -> Poll<io::Result<usize>> {
        unreachable!("header-only probe must not send commands")
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        unreachable!("header-only probe must not flush commands")
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        unreachable!("header-only probe must not shut down writes")
    }
}

async fn read_regions_after_declaration(declared: usize, expected_error: &str) -> Vec<usize> {
    let read_regions = Arc::new(Mutex::new(Vec::new()));
    let probe = HeaderOnlyProbe {
        header: Some(format!("* 1 FETCH (UID 8 BODY[] {{{declared}}}\r\n").into_bytes()),
        read_regions: Arc::clone(&read_regions),
    };
    let mut client = Client::new(probe);
    let error = client
        .read_response()
        .await
        .expect_err("header without literal bytes must not produce a response");
    assert_eq!(error.kind(), io::ErrorKind::Other);
    assert_eq!(error.to_string(), expected_error);
    read_regions.lock().unwrap().clone()
}

#[tokio::test]
async fn ac04_candidate_limitation_allocates_above_raw_limit_before_transport_can_reject() {
    let expected_error = "synthetic transport read budget exhausted";
    let small = read_regions_after_declaration(64, expected_error).await;
    assert_eq!(small.len(), 2);
    assert!(small[1] < small[0]);

    let declared = MAX_RAW_BYTES + 1;
    let oversized = read_regions_after_declaration(declared, expected_error).await;
    assert_eq!(oversized.len(), 2);
    assert_eq!(oversized[0], small[0]);
    // ReadBuf exposes an already initialized region, not just reserved capacity.
    assert!(oversized[1] >= declared);
}

#[tokio::test]
async fn ac04_candidate_fixed_buffer_ceiling_rejects_before_another_transport_read() {
    let regions =
        read_regions_after_declaration(512 * 1024 * 1024 + 1, "incoming data too large").await;
    assert_eq!(regions.len(), 1);
}
