use std::{
    collections::VecDeque,
    io::{self, ErrorKind},
    pin::Pin,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    task::{Context, Poll},
    time::Duration,
};

use tokio::{
    io::{AsyncRead, AsyncWrite, ReadBuf},
    time::Instant,
};

use super::{
    BoundedFramingProbe, BoundedReceiver, COMMAND, FetchError, ReceiveError, SOURCE, checked_fetch,
};

#[derive(Default)]
struct Observed {
    written: Vec<u8>,
    reads: usize,
    flushes: usize,
    dropped: bool,
}

#[derive(Clone, Copy)]
enum WriteEnd {
    Error,
    Zero,
    Pending,
    Complete,
}

struct ScriptedIo {
    observed: Arc<Mutex<Observed>>,
    write_end: WriteEnd,
    flush_error: bool,
    input: VecDeque<Vec<u8>>,
    interrupted: usize,
}

impl Drop for ScriptedIo {
    fn drop(&mut self) {
        self.observed.lock().unwrap().dropped = true;
    }
}

impl AsyncRead for ScriptedIo {
    fn poll_read(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        self.observed.lock().unwrap().reads += 1;
        if let Some(bytes) = self.input.pop_front() {
            assert!(bytes.len() <= buffer.remaining());
            buffer.put_slice(&bytes);
            return Poll::Ready(Ok(()));
        }
        if self.interrupted > 0 {
            self.interrupted -= 1;
            return Poll::Ready(Err(io::Error::from(ErrorKind::Interrupted)));
        }
        Poll::Ready(Err(io::Error::new(
            ErrorKind::ConnectionReset,
            "SYNTHETIC PRIVATE ERROR",
        )))
    }
}

impl AsyncWrite for ScriptedIo {
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let mut observed = self.observed.lock().unwrap();
        let limit = if matches!(self.write_end, WriteEnd::Complete) {
            COMMAND.len()
        } else {
            7
        };
        if observed.written.len() < limit {
            let count = bytes.len().min(3).min(limit - observed.written.len());
            observed.written.extend_from_slice(&bytes[..count]);
            return Poll::Ready(Ok(count));
        }
        match self.write_end {
            WriteEnd::Error => Poll::Ready(Err(io::Error::new(
                ErrorKind::BrokenPipe,
                "SYNTHETIC PRIVATE ERROR",
            ))),
            WriteEnd::Zero => Poll::Ready(Ok(0)),
            WriteEnd::Pending => Poll::Pending,
            WriteEnd::Complete => panic!("FETCH must not retry or send another command"),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        self.observed.lock().unwrap().flushes += 1;
        Poll::Ready(if self.flush_error {
            Err(io::Error::new(
                ErrorKind::BrokenPipe,
                "SYNTHETIC PRIVATE ERROR",
            ))
        } else {
            Ok(())
        })
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        panic!("failed FETCH must drop the transport, not reuse it");
    }
}

fn receiver(
    write_end: WriteEnd,
    flush_error: bool,
    input: Vec<Vec<u8>>,
    interrupted: usize,
) -> (BoundedReceiver<ScriptedIo>, Arc<Mutex<Observed>>) {
    let observed = Arc::new(Mutex::new(Observed::default()));
    (
        BoundedReceiver {
            stream: ScriptedIo {
                observed: Arc::clone(&observed),
                write_end,
                flush_error,
                input: input.into(),
                interrupted,
            },
            framing: BoundedFramingProbe::new(512, 1024),
        },
        observed,
    )
}

#[tokio::test]
async fn ac04_fetch_write_and_flush_failures_drop_transport_without_retry_or_read() {
    for (end, flush_error, expected, sent) in [
        (WriteEnd::Error, false, ErrorKind::BrokenPipe, 7),
        (WriteEnd::Zero, false, ErrorKind::WriteZero, 7),
        (
            WriteEnd::Complete,
            true,
            ErrorKind::BrokenPipe,
            COMMAND.len(),
        ),
    ] {
        let (receiver, observed) = receiver(end, flush_error, vec![], 0);
        let Err(failure) = checked_fetch(
            receiver,
            Instant::now() + Duration::from_secs(1),
            std::future::pending(),
        )
        .await
        else {
            panic!("write failure must not succeed");
        };
        assert_eq!(failure.cause, FetchError::Write(expected));
        assert!(failure.provisional.is_none());
        assert!(failure.wire_prefix.is_empty());
        assert!(!format!("{failure:?}").contains("PRIVATE"));
        let observed = observed.lock().unwrap();
        assert!(observed.dropped);
        assert_eq!(observed.written, COMMAND[..sent]);
        assert_eq!(observed.reads, 0);
        assert_eq!(observed.flushes, usize::from(flush_error));
    }
}

#[tokio::test]
async fn ac04_fetch_pending_partial_write_is_dropped_on_cancel_or_deadline() {
    for cancel in [false, true] {
        let (receiver, observed) = receiver(WriteEnd::Pending, false, vec![], 0);
        let cancellation = async {
            if cancel {
                while observed.lock().unwrap().written.len() < 7 {
                    tokio::task::yield_now().await;
                }
            } else {
                std::future::pending::<()>().await;
            }
        };
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            checked_fetch(
                receiver,
                Instant::now() + Duration::from_millis(50),
                cancellation,
            ),
        )
        .await
        .unwrap();
        let Err(failure) = result else {
            panic!("partial write must not succeed");
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
        let observed = observed.lock().unwrap();
        assert!(observed.dropped);
        assert_eq!(observed.written, COMMAND[..7]);
        assert_eq!(observed.flushes, 0);
        assert_eq!(observed.reads, 0);
    }
}

#[tokio::test]
async fn ac04_fetch_read_error_retains_processed_prefix_and_provisional_body() {
    for complete_body in [false, true] {
        let prefix = if complete_body {
            &b"F0001 OK partial"[..]
        } else {
            &b"* 1 FETCH (UID 8 BODY[] {64}\r\npartial"[..]
        };
        let mut input = Vec::new();
        if complete_body {
            input.push(super::super::super::fetch_response(SOURCE));
        }
        input.push(prefix.to_vec());
        let (receiver, observed) = receiver(WriteEnd::Complete, false, input, 0);
        let Err(failure) = checked_fetch(
            receiver,
            Instant::now() + Duration::from_secs(1),
            std::future::pending(),
        )
        .await
        else {
            panic!("read failure must not succeed");
        };
        assert_eq!(
            failure.cause,
            FetchError::Receive(ReceiveError::Io(ErrorKind::ConnectionReset))
        );
        assert_eq!(
            failure.provisional.as_deref(),
            if complete_body { Some(SOURCE) } else { None }
        );
        assert_eq!(failure.wire_prefix, prefix);
        assert!(!format!("{failure:?}").contains("PRIVATE"));
        let observed = observed.lock().unwrap();
        assert!(observed.dropped);
        assert_eq!(observed.written, COMMAND);
        assert_eq!(observed.flushes, 1);
        assert_eq!(observed.reads, if complete_body { 3 } else { 2 });
    }
}

#[tokio::test(flavor = "current_thread")]
async fn ac04_fetch_interrupted_reads_yield_to_cancelling_task_without_losing_prefix() {
    let prefix = b"* 1 FETCH (UID 8 BODY[] {64}\r\npartial";
    let (receiver, observed) = receiver(WriteEnd::Complete, false, vec![prefix.to_vec()], 10_000);
    let cancelled = Arc::new(AtomicBool::new(false));
    let signal = Arc::clone(&cancelled);
    let state = Arc::clone(&observed);
    let task = tokio::spawn(async move {
        while state.lock().unwrap().reads < 2 {
            tokio::task::yield_now().await;
        }
        signal.store(true, Ordering::SeqCst);
    });
    let cancellation = async {
        while !cancelled.load(Ordering::SeqCst) {
            tokio::task::yield_now().await;
        }
    };
    let Err(failure) = checked_fetch(
        receiver,
        Instant::now() + Duration::from_secs(1),
        cancellation,
    )
    .await
    else {
        panic!("cancelled receive must not succeed");
    };
    task.await.unwrap();
    assert_eq!(failure.cause, FetchError::Cancelled);
    assert_eq!(failure.wire_prefix, prefix);
    assert!(failure.provisional.is_none());
    let observed = observed.lock().unwrap();
    assert!(observed.dropped);
    assert!((2..10_002).contains(&observed.reads));
    assert_eq!(observed.written, COMMAND);
}
