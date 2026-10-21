use std::{error::Error, fmt};

use mail_parser::{Message, MessageParser, PartType};

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
