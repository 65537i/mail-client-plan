use std::{
    error::Error,
    fmt,
    future::Future,
    io::{self, Read},
};

use mail_parser::{Message, MessageParser, PartType};
use tokio::{
    io::{AsyncRead, AsyncReadExt},
    time::Instant,
};

pub const MAX_RAW_BYTES: usize = 50 * 1024 * 1024;
pub const MAX_DECODED_BYTES: usize = 100 * 1024 * 1024;
pub const MAX_ATTACHMENT_BYTES: usize = 25 * 1024 * 1024;
pub const MAX_NESTING: usize = 30;

#[derive(Debug, PartialEq, Eq)]
pub enum MimeError {
    RawTooLarge,
    AttachmentTooLarge,
    DecodedTooLarge,
    NestingTooDeep,
    Unparseable,
    Incomplete,
    InvalidStructure,
}

impl fmt::Display for MimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::RawTooLarge => "MIME source exceeds 50 MiB",
            Self::AttachmentTooLarge => "MIME attachment exceeds 25 MiB",
            Self::DecodedTooLarge => "MIME decoded content exceeds 100 MiB",
            Self::NestingTooDeep => "MIME nesting exceeds 30 containers",
            Self::Unparseable => "MIME source could not be parsed",
            Self::Incomplete => "MIME content is incomplete or has transfer encoding errors",
            Self::InvalidStructure => "MIME parser returned an invalid part structure",
        })
    }
}

impl Error for MimeError {}

pub struct SourceReadError {
    partial: Vec<u8>,
    cause: SourceReadCause,
}

pub enum SourceReadCause {
    TooLarge,
    Io(io::Error),
    TimedOut,
    Cancelled,
}

impl SourceReadError {
    pub fn into_parts(self) -> (Vec<u8>, SourceReadCause) {
        (self.partial, self.cause)
    }
}

impl fmt::Display for SourceReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.cause {
            SourceReadCause::TimedOut => {
                f.write_str("MIME source read deadline expired; retained bytes may be incomplete")
            }
            SourceReadCause::Cancelled => {
                f.write_str("MIME source read cancelled; retained bytes may be incomplete")
            }
            SourceReadCause::TooLarge => {
                f.write_str("MIME source exceeds 50 MiB; retained bytes are only a prefix")
            }
            SourceReadCause::Io(error) => write!(
                f,
                "MIME source read failed ({:?}); retained bytes may be incomplete",
                error.kind()
            ),
        }
    }
}

impl fmt::Debug for SourceReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SourceReadError")
            .field("retained_bytes", &self.partial.len())
            .field("reason", &self.to_string())
            .finish()
    }
}

// Do not expose the I/O source through error formatting: it can contain private paths.
impl Error for SourceReadError {}

/// Blocking PoC reader; caller controls cancellation/timeouts and retains the unread stream.
/// Reads at most 50 MiB plus one byte to distinguish exact-limit EOF from overflow.
pub fn read_source(reader: &mut impl Read) -> Result<Vec<u8>, SourceReadError> {
    let mut raw = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        let remaining = (MAX_RAW_BYTES + 1 - raw.len()).min(chunk.len());
        match reader.read(&mut chunk[..remaining]) {
            Ok(0) => return Ok(raw),
            Ok(count) => {
                raw.extend_from_slice(&chunk[..count]);
                if raw.len() > MAX_RAW_BYTES {
                    return Err(SourceReadError {
                        partial: raw,
                        cause: SourceReadCause::TooLarge,
                    });
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => {
                return Err(SourceReadError {
                    partial: raw,
                    cause: SourceReadCause::Io(error),
                });
            }
        }
    }
}

/// Deadline applies to the whole read, not each chunk. A ready cancellation wins
/// over a ready timeout/read; Tokio read is cancellation-safe.
pub async fn read_source_async(
    reader: &mut (impl AsyncRead + Unpin),
    deadline: Instant,
    cancellation: impl Future<Output = ()>,
) -> Result<Vec<u8>, SourceReadError> {
    let mut raw = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    tokio::pin!(cancellation);
    loop {
        let remaining = (MAX_RAW_BYTES + 1 - raw.len()).min(chunk.len());
        let timeout = async {
            if Instant::now() < deadline {
                tokio::time::sleep_until(deadline).await;
            }
        };
        let result = tokio::select! {
            biased;
            () = &mut cancellation => return Err(SourceReadError {
                partial: raw, cause: SourceReadCause::Cancelled,
            }),
            () = timeout => return Err(SourceReadError {
                partial: raw, cause: SourceReadCause::TimedOut,
            }),
            result = reader.read(&mut chunk[..remaining]) => result,
        };
        match result {
            Ok(0) => return Ok(raw),
            Ok(count) => {
                raw.extend_from_slice(&chunk[..count]);
                if raw.len() > MAX_RAW_BYTES {
                    return Err(SourceReadError {
                        partial: raw,
                        cause: SourceReadCause::TooLarge,
                    });
                }
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => {
                return Err(SourceReadError {
                    partial: raw,
                    cause: SourceReadCause::Io(error),
                });
            }
        }
        tokio::task::yield_now().await;
    }
}

/// PoC limits only: output remains untrusted, and parsing itself is not resource-bounded.
/// The caller retains ownership of the source even when validation fails.
pub fn parse(raw: &[u8]) -> Result<Message<'_>, MimeError> {
    if raw.len() > MAX_RAW_BYTES {
        return Err(MimeError::RawTooLarge);
    }
    let message = MessageParser::default()
        .parse(raw)
        .ok_or(MimeError::Unparseable)?;
    validate(&message)?;
    Ok(message)
}

fn validate(message: &Message<'_>) -> Result<(), MimeError> {
    let mut pending = vec![(message, 0usize, 0usize)];
    let mut decoded = 0usize;
    while let Some((message, index, depth)) = pending.pop() {
        let part = message
            .parts
            .get(index)
            .ok_or(MimeError::InvalidStructure)?;
        if part.is_encoding_problem {
            return Err(MimeError::Incomplete);
        }
        let size = part.contents().len();
        if (message.attachments.contains(&(index as u32))
            || matches!(
                part.body,
                PartType::Binary(_) | PartType::InlineBinary(_) | PartType::Message(_)
            ))
            && size > MAX_ATTACHMENT_BYTES
        {
            return Err(MimeError::AttachmentTooLarge);
        }
        // Nested message source and its decoded leaves both consume the budget.
        decoded = decoded
            .checked_add(size)
            .ok_or(MimeError::DecodedTooLarge)?;
        if decoded > MAX_DECODED_BYTES {
            return Err(MimeError::DecodedTooLarge);
        }
        match &part.body {
            PartType::Multipart(children) => {
                if depth >= MAX_NESTING {
                    return Err(MimeError::NestingTooDeep);
                }
                if children.is_empty() {
                    return Err(MimeError::Incomplete);
                }
                for child in children {
                    pending.push((message, *child as usize, depth + 1));
                }
            }
            PartType::Message(nested) => {
                if depth >= MAX_NESTING {
                    return Err(MimeError::NestingTooDeep);
                }
                pending.push((nested, 0, depth + 1));
            }
            _ => {}
        }
    }
    if message.text_body.is_empty()
        && message.html_body.is_empty()
        && message.attachments.is_empty()
    {
        return Err(MimeError::Incomplete);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use mail_parser::MessagePart;

    #[test]
    fn source_reader_handles_empty_and_small_mime_sources() {
        for source in [&b""[..], b"Content-Type: text/plain\r\n\r\nSynthetic"] {
            let raw = read_source(&mut io::Cursor::new(source)).expect("complete MIME source");
            assert_eq!(raw, source);
            if !raw.is_empty() {
                assert_eq!(
                    parse(&raw).unwrap().body_text(0).as_deref(),
                    Some("Synthetic")
                );
            }
        }
    }

    #[test]
    fn source_reader_accepts_raw_boundary_and_stops_at_first_excess_byte() {
        for size in [
            MAX_RAW_BYTES - 1,
            MAX_RAW_BYTES,
            MAX_RAW_BYTES + 1,
            MAX_RAW_BYTES + 100,
        ] {
            let mut reader = io::repeat(b'x').take(size as u64);
            match read_source(&mut reader) {
                Ok(raw) => {
                    assert!(size <= MAX_RAW_BYTES);
                    assert_eq!(raw.len(), size);
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

    struct InterruptedThenFailure {
        calls: usize,
    }

    impl Read for InterruptedThenFailure {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            self.calls += 1;
            match self.calls {
                1 => Err(io::ErrorKind::Interrupted.into()),
                2 => {
                    let source = b"private-source";
                    buffer[..source.len()].copy_from_slice(source);
                    Ok(source.len())
                }
                _ => Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "private-path-detail",
                )),
            }
        }
    }

    #[test]
    fn source_reader_preserves_partial_bytes_and_original_error_without_logging_them() {
        let mut reader = InterruptedThenFailure { calls: 0 };
        let error = read_source(&mut reader).expect_err("read failure is not EOF");
        assert_eq!(reader.calls, 3);
        for diagnostic in [error.to_string(), format!("{error:?}")] {
            assert!(!diagnostic.contains("private-source"));
            assert!(!diagnostic.contains("private-path-detail"));
            assert!(diagnostic.contains("PermissionDenied"));
        }
        assert!(error.source().is_none());
        let (prefix, cause) = error.into_parts();
        assert_eq!(prefix, b"private-source");
        let SourceReadCause::Io(original) = cause else {
            panic!("expected original I/O failure");
        };
        assert_eq!(original.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(original.to_string(), "private-path-detail");
    }

    #[test]
    fn source_reader_supports_short_reads_without_changing_mime_bytes() {
        struct ShortReader(io::Cursor<&'static [u8]>);
        impl Read for ShortReader {
            fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
                Read::read(&mut self.0, &mut buffer[..1])
            }
        }
        let source = b"Content-Type: text/plain\r\n\r\nSynthetic";
        let raw = read_source(&mut ShortReader(io::Cursor::new(source))).unwrap();
        assert_eq!(raw, source);
    }

    #[test]
    fn decoded_budget_checks_exact_boundary_without_allocating_100_mib() {
        let payload = vec![b'x'; MAX_ATTACHMENT_BYTES];
        for (last_size, expected) in [
            (MAX_ATTACHMENT_BYTES - 1, Ok(())),
            (MAX_ATTACHMENT_BYTES, Ok(())),
            (MAX_ATTACHMENT_BYTES + 1, Err(MimeError::DecodedTooLarge)),
        ] {
            let mut message = Message::default();
            message.parts.push(MessagePart {
                body: PartType::Multipart(vec![1, 2, 3, 4, 5]),
                ..Default::default()
            });
            for _ in 0..3 {
                message.parts.push(MessagePart {
                    body: PartType::Binary(payload.as_slice().into()),
                    ..Default::default()
                });
            }
            message.parts.push(MessagePart {
                body: PartType::Binary(payload[..last_size.min(MAX_ATTACHMENT_BYTES)].into()),
                ..Default::default()
            });
            message.parts.push(MessagePart {
                body: PartType::Binary(
                    payload[..usize::from(last_size > MAX_ATTACHMENT_BYTES)].into(),
                ),
                ..Default::default()
            });
            message.attachments = vec![1, 2, 3, 4, 5];
            assert_eq!(validate(&message), expected);
        }
    }
}
