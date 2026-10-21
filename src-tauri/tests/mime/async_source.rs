use std::{
    future::{pending, poll_fn, ready},
    io,
    pin::Pin,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll},
    time::Duration,
};

use mail_client_lib::mime_poc::{MAX_RAW_BYTES, SourceReadCause, read_source_async};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt, ReadBuf},
    time::Instant,
};

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(10)
}

#[tokio::test]
async fn cancellation_interrupts_pending_io_and_preserves_the_stream() {
    let (mut writer, mut reader) = tokio::io::duplex(64);
    writer.write_all(b"Synthetic prefix").await.unwrap();
    let result = tokio::time::timeout(
        Duration::from_secs(2),
        read_source_async(&mut reader, deadline(), async {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }),
    )
    .await
    .expect("cancellation must interrupt pending I/O");
    let (prefix, cause) = result.unwrap_err().into_parts();
    assert_eq!(prefix, b"Synthetic prefix");
    assert!(matches!(cause, SourceReadCause::Cancelled));
    writer.write_all(b"suffix").await.unwrap();
    let mut suffix = [0; 6];
    reader.read_exact(&mut suffix).await.unwrap();
    assert_eq!(&suffix, b"suffix");
}

#[tokio::test]
async fn async_source_accepts_empty_small_and_exact_boundary_inputs() {
    for source in [&b""[..], b"Content-Type: text/plain\r\n\r\nSynthetic"] {
        let mut reader = source;
        assert_eq!(
            read_source_async(&mut reader, deadline(), pending())
                .await
                .unwrap(),
            source
        );
    }
    for size in [
        MAX_RAW_BYTES - 1,
        MAX_RAW_BYTES,
        MAX_RAW_BYTES + 1,
        MAX_RAW_BYTES + 100,
    ] {
        let mut reader = tokio::io::repeat(b'x').take(size as u64);
        match read_source_async(&mut reader, deadline(), pending()).await {
            Ok(raw) => {
                assert!(size <= MAX_RAW_BYTES);
                assert_eq!(raw.len(), size);
                assert!(raw.iter().all(|byte| *byte == b'x'));
            }
            Err(error) => {
                assert!(size > MAX_RAW_BYTES);
                let (prefix, cause) = error.into_parts();
                assert!(matches!(cause, SourceReadCause::TooLarge));
                assert_eq!(prefix.len(), MAX_RAW_BYTES + 1);
                assert!(prefix.iter().all(|byte| *byte == b'x'));
                assert_eq!(reader.limit(), (size - MAX_RAW_BYTES - 1) as u64);
            }
        }
    }
}

#[tokio::test]
async fn ready_cancellation_and_expired_deadline_do_not_consume_input() {
    let source = b"Synthetic unread source";
    let mut reader = &source[..];
    let (prefix, cause) = read_source_async(&mut reader, Instant::now(), ready(()))
        .await
        .unwrap_err()
        .into_parts();
    assert!(matches!(cause, SourceReadCause::Cancelled));
    assert!(prefix.is_empty());
    assert_eq!(reader, source);
    let (prefix, cause) = read_source_async(&mut reader, Instant::now(), pending())
        .await
        .unwrap_err()
        .into_parts();
    assert!(matches!(cause, SourceReadCause::TimedOut));
    assert!(prefix.is_empty());
    assert_eq!(reader, source);
}

#[tokio::test]
async fn deadline_interrupts_a_stalled_read_and_returns_prefix() {
    let (mut writer, mut reader) = tokio::io::duplex(64);
    writer.write_all(b"Synthetic prefix").await.unwrap();
    let error = tokio::time::timeout(
        Duration::from_secs(2),
        read_source_async(
            &mut reader,
            Instant::now() + Duration::from_millis(30),
            pending(),
        ),
    )
    .await
    .expect("read deadline must stop pending I/O")
    .unwrap_err();
    let (prefix, cause) = error.into_parts();
    assert_eq!(prefix, b"Synthetic prefix");
    assert!(matches!(cause, SourceReadCause::TimedOut));
    writer.write_all(b"unread suffix").await.unwrap();
    let mut suffix = [0; 13];
    reader.read_exact(&mut suffix).await.unwrap();
    assert_eq!(&suffix, b"unread suffix");
}

struct ScriptedReader {
    calls: usize,
    cancel: Arc<AtomicBool>,
    cancel_after_prefix: bool,
}

impl AsyncRead for ScriptedReader {
    fn poll_read(
        mut self: Pin<&mut Self>,
        _: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        self.calls += 1;
        Poll::Ready(match self.calls {
            1 => Err(io::ErrorKind::Interrupted.into()),
            2 => {
                buffer.put_slice(b"private-prefix");
                self.cancel
                    .store(self.cancel_after_prefix, Ordering::SeqCst);
                Ok(())
            }
            _ => Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "private-path-detail",
            )),
        })
    }
}

#[tokio::test]
async fn cancellation_after_partial_read_wins_without_another_read() {
    let cancel = Arc::new(AtomicBool::new(false));
    let mut reader = ScriptedReader {
        calls: 0,
        cancel: cancel.clone(),
        cancel_after_prefix: true,
    };
    let cancellation = poll_fn(|_| {
        if cancel.load(Ordering::SeqCst) {
            Poll::Ready(())
        } else {
            Poll::Pending
        }
    });
    let (prefix, cause) = read_source_async(&mut reader, deadline(), cancellation)
        .await
        .unwrap_err()
        .into_parts();
    assert_eq!(reader.calls, 2);
    assert_eq!(prefix, b"private-prefix");
    assert!(matches!(cause, SourceReadCause::Cancelled));
}

#[tokio::test]
async fn async_io_failure_retains_prefix_and_redacts_original_error() {
    let mut reader = ScriptedReader {
        calls: 0,
        cancel: Arc::new(AtomicBool::new(false)),
        cancel_after_prefix: false,
    };
    let error = read_source_async(&mut reader, deadline(), pending())
        .await
        .unwrap_err();
    for diagnostic in [error.to_string(), format!("{error:?}")] {
        assert!(!diagnostic.contains("private-prefix"));
        assert!(!diagnostic.contains("private-path-detail"));
        assert!(diagnostic.contains("PermissionDenied"));
    }
    let (prefix, cause) = error.into_parts();
    assert_eq!(prefix, b"private-prefix");
    let SourceReadCause::Io(original) = cause else {
        panic!("expected I/O failure")
    };
    assert_eq!(original.kind(), io::ErrorKind::PermissionDenied);
    assert_eq!(original.to_string(), "private-path-detail");
}
