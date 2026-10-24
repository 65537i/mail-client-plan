use encoding_rs::{Decoder, DecoderResult, Encoding};
use std::{
    error::Error,
    fmt,
    io::{self, Write},
    ops::Range,
};

pub const MAX_RAW_BYTES: usize = 50 * 1024 * 1024;
pub const MAX_PHYSICAL_HEADER_LINE_BYTES: usize = 998;
pub const MAX_UNFOLDED_HEADER_VALUE_BYTES: usize = 32 * 1024;
pub const MAX_HEADER_BLOCK_BYTES: usize = 1024 * 1024;
pub const MAX_MIME_PARTS: usize = 4096;
pub const MAX_MIME_NESTING: usize = 30;
pub const MAX_DECODED_BYTES: usize = 100 * 1024 * 1024;
pub const MAX_ATTACHMENT_BYTES: usize = 25 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParseError {
    RawTooLarge,
    HeaderBlockTooLarge,
    HeaderLineTooLong,
    HeaderValueTooLarge,
    InvalidLineEnding,
    InvalidHeaderName,
    InvalidContentType,
    ContinuationWithoutHeader,
    MissingHeaderBodySeparator,
    InvalidBoundary,
    InvalidTransferEncoding,
    IncompleteMultipart,
    TooManyParts,
    NestingTooDeep,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::RawTooLarge => "message exceeds 50 MiB",
            Self::HeaderBlockTooLarge => "message header block exceeds 1 MiB",
            Self::HeaderLineTooLong => "physical header line exceeds 998 octets",
            Self::HeaderValueTooLarge => "unfolded header field exceeds 32 KiB",
            Self::InvalidLineEnding => "bare carriage return in message headers",
            Self::InvalidHeaderName => "invalid RFC 5322 header field name",
            Self::InvalidContentType => "invalid MIME Content-Type field",
            Self::ContinuationWithoutHeader => "header continuation has no preceding field",
            Self::MissingHeaderBodySeparator => "message has no complete header/body separator",
            Self::InvalidBoundary => "invalid MIME multipart boundary",
            Self::InvalidTransferEncoding => "invalid MIME Content-Transfer-Encoding field",
            Self::IncompleteMultipart => "MIME multipart closing boundary is missing",
            Self::TooManyParts => "message exceeds 4096 MIME parts",
            Self::NestingTooDeep => "message MIME nesting exceeds 30 containers",
        })
    }
}

impl Error for ParseError {}

pub struct Message<'a> {
    raw: &'a [u8],
    headers_end: usize,
    body: Range<usize>,
    header_count: usize,
}

pub struct MimeDocument<'a> {
    raw: &'a [u8],
    parts: Vec<MimePart>,
}

#[derive(Default)]
pub struct StructureBudget {
    parts: usize,
    header_bytes: usize,
}

impl StructureBudget {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn parts(&self) -> usize {
        self.parts
    }

    pub fn header_bytes(&self) -> usize {
        self.header_bytes
    }
}

pub struct MimePart {
    headers: Range<usize>,
    body: Range<usize>,
    parent: Option<usize>,
    nesting_depth: usize,
    kind: MimePartKind,
    transfer_encoding: TransferEncoding,
    charset: Option<Vec<u8>>,
    is_text: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MimePartKind {
    Leaf,
    Multipart,
    EncapsulatedMessage,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TransferEncoding {
    SevenBit,
    EightBit,
    Binary,
    Base64,
    QuotedPrintable,
    Other,
}

#[derive(Debug)]
pub enum DecodeError {
    InvalidPartIndex,
    MultipartPart,
    NotEncapsulatedMessage,
    UnsupportedTransferEncoding,
    MalformedTransferEncoding,
    DecodedTooLarge,
    AttachmentTooLarge,
    NonTextPart,
    UnsupportedCharset,
    MalformedCharset,
    DecoderStalled,
    Io(io::Error),
}

impl PartialEq for DecodeError {
    fn eq(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::InvalidPartIndex, Self::InvalidPartIndex)
            | (Self::MultipartPart, Self::MultipartPart)
            | (Self::NotEncapsulatedMessage, Self::NotEncapsulatedMessage)
            | (Self::UnsupportedTransferEncoding, Self::UnsupportedTransferEncoding)
            | (Self::MalformedTransferEncoding, Self::MalformedTransferEncoding)
            | (Self::DecodedTooLarge, Self::DecodedTooLarge)
            | (Self::AttachmentTooLarge, Self::AttachmentTooLarge)
            | (Self::NonTextPart, Self::NonTextPart)
            | (Self::UnsupportedCharset, Self::UnsupportedCharset)
            | (Self::MalformedCharset, Self::MalformedCharset)
            | (Self::DecoderStalled, Self::DecoderStalled) => true,
            (Self::Io(left), Self::Io(right)) => {
                left.kind() == right.kind() && left.raw_os_error() == right.raw_os_error()
            }
            _ => false,
        }
    }
}

impl Eq for DecodeError {}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::InvalidPartIndex => "MIME part index is invalid",
            Self::MultipartPart => "multipart containers do not have a decodable leaf body",
            Self::NotEncapsulatedMessage => "MIME part is not an encapsulated message",
            Self::UnsupportedTransferEncoding => "unsupported MIME transfer encoding",
            Self::MalformedTransferEncoding => "malformed MIME transfer-encoded body",
            Self::DecodedTooLarge => "MIME decoded content exceeds 100 MiB",
            Self::AttachmentTooLarge => "MIME attachment exceeds 25 MiB",
            Self::NonTextPart => "MIME part is not a text or HTML part",
            Self::UnsupportedCharset => "MIME text charset is unsupported",
            Self::MalformedCharset => "MIME text is invalid in its declared charset",
            Self::DecoderStalled => "MIME charset decoder made no progress",
            Self::Io(_) => "failed to write decoded MIME content",
        })
    }
}

impl Error for DecodeError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for DecodeError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

#[derive(Default)]
pub struct DecodeBudget {
    decoded_bytes: usize,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DecodeDiagnostics {
    pub charset_defaulted_to_utf8: bool,
    pub replacement_character_present: bool,
    /// A quoted-printable soft break used LF without the canonical preceding CR.
    pub quoted_printable_soft_break_lf_only: bool,
    /// A quoted-printable physical line ended in a literal space or tab.
    pub quoted_printable_trailing_whitespace_unencoded: bool,
}

impl DecodeBudget {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn decoded_bytes(&self) -> usize {
        self.decoded_bytes
    }
}

pub struct Header<'a> {
    name: &'a [u8],
    raw_value: &'a [u8],
}

pub struct Headers<'a> {
    raw: &'a [u8],
    cursor: usize,
    headers_end: usize,
}

struct Line {
    content_end: usize,
    next: usize,
}

struct MultipartFrame {
    body: Range<usize>,
    boundary: Vec<u8>,
    search_from: usize,
    current_part_start: Option<usize>,
    parent_part: usize,
    child_depth: usize,
    closing_seen: bool,
}

struct Delimiter {
    line_start: usize,
    after_line: usize,
    closing: bool,
}

struct ContentType {
    media_type: Vec<u8>,
    boundary: Option<Vec<u8>>,
    charset: Option<Vec<u8>>,
}

#[derive(Clone, Copy)]
struct DecodeLimits {
    decoded: usize,
    attachment: usize,
}

struct BudgetedWriter<'a, W> {
    sink: &'a mut W,
    budget: &'a mut DecodeBudget,
    limits: DecodeLimits,
    is_attachment: bool,
    attachment_bytes: usize,
    buffer: [u8; 1024],
    buffered: usize,
}

trait DecodeOutput {
    fn push(&mut self, byte: u8) -> Result<(), DecodeError>;

    fn extend(&mut self, bytes: &[u8]) -> Result<(), DecodeError> {
        for byte in bytes {
            self.push(*byte)?;
        }
        Ok(())
    }
}

impl<'a, W: Write> BudgetedWriter<'a, W> {
    fn new(
        sink: &'a mut W,
        budget: &'a mut DecodeBudget,
        is_attachment: bool,
        limits: DecodeLimits,
    ) -> Self {
        Self {
            sink,
            budget,
            limits,
            is_attachment,
            attachment_bytes: 0,
            buffer: [0; 1024],
            buffered: 0,
        }
    }

    fn push(&mut self, byte: u8) -> Result<(), DecodeError> {
        if self.is_attachment && self.attachment_bytes >= self.limits.attachment {
            return Err(DecodeError::AttachmentTooLarge);
        }
        if self.budget.decoded_bytes >= self.limits.decoded {
            return Err(DecodeError::DecodedTooLarge);
        }
        self.budget.decoded_bytes += 1;
        if self.is_attachment {
            self.attachment_bytes += 1;
        }
        self.buffer[self.buffered] = byte;
        self.buffered += 1;
        if self.buffered == self.buffer.len() {
            self.flush()?;
        }
        Ok(())
    }

    fn flush(&mut self) -> Result<(), DecodeError> {
        self.sink.write_all(&self.buffer[..self.buffered])?;
        self.buffered = 0;
        Ok(())
    }

    fn finish(&mut self) -> Result<(), DecodeError> {
        self.flush()
    }
}

impl<W: Write> DecodeOutput for BudgetedWriter<'_, W> {
    fn push(&mut self, byte: u8) -> Result<(), DecodeError> {
        BudgetedWriter::push(self, byte)
    }
}

struct CharsetBudgetedWriter<'a, W> {
    sink: &'a mut W,
    budget: &'a mut DecodeBudget,
    decoder: Decoder,
    limits: DecodeLimits,
    is_attachment: bool,
    attachment_bytes: usize,
    diagnostics: &'a mut DecodeDiagnostics,
    replacement_detector: ReplacementDetector,
    input: [u8; 1024],
    input_len: usize,
}

#[derive(Default)]
struct ReplacementDetector {
    state: u8,
}

impl ReplacementDetector {
    fn observe(&mut self, bytes: &[u8], diagnostics: &mut DecodeDiagnostics) {
        for byte in bytes {
            self.state = match (self.state, *byte) {
                (0, 0xef) | (1, 0xef) | (2, 0xef) => 1,
                (1, 0xbf) => 2,
                (2, 0xbd) => {
                    diagnostics.replacement_character_present = true;
                    0
                }
                _ => 0,
            };
        }
    }
}

impl<'a, W: Write> CharsetBudgetedWriter<'a, W> {
    fn new(
        sink: &'a mut W,
        budget: &'a mut DecodeBudget,
        encoding: &'static Encoding,
        is_attachment: bool,
        limits: DecodeLimits,
        diagnostics: &'a mut DecodeDiagnostics,
    ) -> Self {
        Self {
            sink,
            budget,
            decoder: encoding.new_decoder_without_bom_handling(),
            limits,
            is_attachment,
            attachment_bytes: 0,
            diagnostics,
            replacement_detector: ReplacementDetector::default(),
            input: [0; 1024],
            input_len: 0,
        }
    }

    fn process(&mut self, last: bool) -> Result<(), DecodeError> {
        let mut consumed = 0usize;
        let mut output = [0u8; 4096];
        loop {
            let (result, read, written) = self.decoder.decode_to_utf8_without_replacement(
                &self.input[consumed..self.input_len],
                &mut output,
                last,
            );
            for _ in &output[..written] {
                if self.is_attachment && self.attachment_bytes >= self.limits.attachment {
                    return Err(DecodeError::AttachmentTooLarge);
                }
                if self.budget.decoded_bytes >= self.limits.decoded {
                    return Err(DecodeError::DecodedTooLarge);
                }
                self.budget.decoded_bytes += 1;
                if self.is_attachment {
                    self.attachment_bytes += 1;
                }
            }
            self.replacement_detector
                .observe(&output[..written], self.diagnostics);
            self.sink.write_all(&output[..written])?;
            consumed += read;
            match result {
                DecoderResult::InputEmpty => {
                    self.input.copy_within(consumed..self.input_len, 0);
                    self.input_len -= consumed;
                    return Ok(());
                }
                DecoderResult::OutputFull => {
                    if read == 0 && written == 0 {
                        return Err(DecodeError::DecoderStalled);
                    }
                }
                DecoderResult::Malformed(_, _) => return Err(DecodeError::MalformedCharset),
            }
        }
    }

    fn finish(&mut self) -> Result<(), DecodeError> {
        self.process(true)
    }
}

impl<W: Write> DecodeOutput for CharsetBudgetedWriter<'_, W> {
    fn push(&mut self, byte: u8) -> Result<(), DecodeError> {
        if self.budget.decoded_bytes >= self.limits.decoded {
            return Err(DecodeError::DecodedTooLarge);
        }
        self.budget.decoded_bytes += 1;
        self.input[self.input_len] = byte;
        self.input_len += 1;
        if self.input_len == self.input.len() {
            self.process(false)?;
        }
        Ok(())
    }
}

impl<'a> Message<'a> {
    pub fn parse(raw: &'a [u8]) -> Result<Self, ParseError> {
        if raw.len() > MAX_RAW_BYTES {
            return Err(ParseError::RawTooLarge);
        }

        let mut cursor = 0usize;
        let mut header_count = 0usize;
        let mut has_previous_header = false;

        loop {
            let line = read_line(raw, cursor)?;
            if line.next > MAX_HEADER_BLOCK_BYTES {
                return Err(ParseError::HeaderBlockTooLarge);
            }

            if cursor == line.content_end {
                return Ok(Self {
                    raw,
                    headers_end: line.next,
                    body: line.next..raw.len(),
                    header_count,
                });
            }

            let first = raw[cursor];
            if first == b' ' || first == b'\t' {
                if !has_previous_header {
                    return Err(ParseError::ContinuationWithoutHeader);
                }
                cursor = line.next;
                continue;
            }

            let colon = raw[cursor..line.content_end]
                .iter()
                .position(|byte| *byte == b':')
                .map(|offset| cursor + offset)
                .filter(|colon| *colon > cursor)
                .ok_or(ParseError::InvalidHeaderName)?;
            if !raw[cursor..colon].iter().copied().all(is_field_name_byte) {
                return Err(ParseError::InvalidHeaderName);
            }

            let mut unfolded_len = line.content_end - colon - 1;
            if unfolded_len > MAX_UNFOLDED_HEADER_VALUE_BYTES {
                return Err(ParseError::HeaderValueTooLarge);
            }
            cursor = line.next;

            loop {
                let continuation = read_line(raw, cursor)?;
                if continuation.next > MAX_HEADER_BLOCK_BYTES {
                    return Err(ParseError::HeaderBlockTooLarge);
                }
                if cursor == continuation.content_end {
                    break;
                }

                let byte = raw[cursor];
                if byte != b' ' && byte != b'\t' {
                    break;
                }
                let content = &raw[cursor..continuation.content_end];
                unfolded_len = unfolded_len
                    .checked_add(content.len())
                    .ok_or(ParseError::HeaderValueTooLarge)?;
                if unfolded_len > MAX_UNFOLDED_HEADER_VALUE_BYTES {
                    return Err(ParseError::HeaderValueTooLarge);
                }
                cursor = continuation.next;
            }

            header_count += 1;
            has_previous_header = true;
        }
    }

    pub fn headers(&self) -> Headers<'a> {
        Headers {
            raw: self.raw,
            cursor: 0,
            headers_end: self.headers_end,
        }
    }

    pub fn header_count(&self) -> usize {
        self.header_count
    }

    pub fn body(&self) -> &'a [u8] {
        &self.raw[self.body.clone()]
    }

    pub fn body_range(&self) -> Range<usize> {
        self.body.clone()
    }

    pub fn header_block_range(&self) -> Range<usize> {
        0..self.headers_end
    }
}

impl<'a> MimeDocument<'a> {
    pub fn parse(raw: &'a [u8]) -> Result<Self, ParseError> {
        Self::parse_nested(raw, 0, &mut StructureBudget::new())
    }

    /// Parses an encapsulated message using its parent's absolute nesting depth and shared
    /// part/header budget. Discard the budget if parsing fails.
    pub fn parse_nested(
        raw: &'a [u8],
        nesting_depth: usize,
        structure_budget: &mut StructureBudget,
    ) -> Result<Self, ParseError> {
        if raw.len() > MAX_RAW_BYTES {
            return Err(ParseError::RawTooLarge);
        }
        if nesting_depth > MAX_MIME_NESTING {
            return Err(ParseError::NestingTooDeep);
        }

        let mut parts = Vec::new();
        let mut pending = Some((0..raw.len(), None, nesting_depth));
        let mut multipart_stack: Vec<MultipartFrame> = Vec::new();

        loop {
            if let Some((entity_range, parent, nesting_depth)) = pending.take() {
                if structure_budget.parts >= MAX_MIME_PARTS {
                    return Err(ParseError::TooManyParts);
                }
                let entity = &raw[entity_range.clone()];
                let message = Message::parse(entity)?;
                structure_budget.header_bytes = structure_budget
                    .header_bytes
                    .checked_add(message.header_block_range().len())
                    .ok_or(ParseError::HeaderBlockTooLarge)?;
                if structure_budget.header_bytes > MAX_HEADER_BLOCK_BYTES {
                    return Err(ParseError::HeaderBlockTooLarge);
                }

                let part_index = parts.len();
                let part_headers = entity_range.start..entity_range.start + message.headers_end;
                let part_body =
                    entity_range.start + message.body.start..entity_range.start + message.body.end;
                let content_type = Header::content_type(&message)?;
                let transfer_encoding = Header::transfer_encoding(&message)?;
                let (kind, boundary, charset, is_text) = match content_type {
                    Some(ContentType {
                        media_type,
                        boundary,
                        charset,
                    }) if media_type.eq_ignore_ascii_case(b"multipart") => {
                        let boundary = boundary.ok_or(ParseError::InvalidBoundary)?;
                        let depth = nesting_depth + 1;
                        if depth > MAX_MIME_NESTING {
                            return Err(ParseError::NestingTooDeep);
                        }
                        (
                            MimePartKind::Multipart,
                            Some((boundary, depth)),
                            charset,
                            false,
                        )
                    }
                    Some(ContentType {
                        media_type,
                        charset,
                        ..
                    }) if media_type.eq_ignore_ascii_case(b"message/rfc822") => {
                        let depth = nesting_depth + 1;
                        if depth > MAX_MIME_NESTING {
                            return Err(ParseError::NestingTooDeep);
                        }
                        (MimePartKind::EncapsulatedMessage, None, charset, false)
                    }
                    Some(ContentType {
                        media_type,
                        charset,
                        ..
                    }) => (
                        MimePartKind::Leaf,
                        None,
                        charset,
                        media_type
                            .get(..5)
                            .is_some_and(|prefix| prefix.eq_ignore_ascii_case(b"text/")),
                    ),
                    None => (MimePartKind::Leaf, None, None, false),
                };
                structure_budget.parts += 1;
                parts.push(MimePart {
                    headers: part_headers,
                    body: part_body.clone(),
                    parent,
                    nesting_depth,
                    kind,
                    transfer_encoding,
                    charset,
                    is_text,
                });

                match kind {
                    MimePartKind::Multipart => {
                        let (boundary, child_depth) = boundary.expect("multipart boundary");
                        let search_from = part_body.start;
                        multipart_stack.push(MultipartFrame {
                            body: part_body,
                            boundary,
                            search_from,
                            current_part_start: None,
                            parent_part: part_index,
                            child_depth,
                            closing_seen: false,
                        });
                    }
                    MimePartKind::EncapsulatedMessage => {
                        if matches!(
                            transfer_encoding,
                            TransferEncoding::SevenBit
                                | TransferEncoding::EightBit
                                | TransferEncoding::Binary
                        ) {
                            pending = Some((part_body, Some(part_index), nesting_depth + 1));
                        }
                    }
                    MimePartKind::Leaf => {}
                }
                continue;
            }

            let Some(frame) = multipart_stack.last_mut() else {
                break;
            };
            match frame.next_part(raw)? {
                Some(child) => {
                    pending = Some((child, Some(frame.parent_part), frame.child_depth));
                }
                None => {
                    multipart_stack.pop();
                }
            }
        }

        Ok(Self { raw, parts })
    }

    pub fn parts(&self) -> &[MimePart] {
        &self.parts
    }

    pub fn raw(&self) -> &'a [u8] {
        self.raw
    }

    pub fn part_headers(&self, part_index: usize) -> Option<&'a [u8]> {
        let part = self.parts.get(part_index)?;
        Some(&self.raw[part.headers.clone()])
    }

    pub fn part_body(&self, part_index: usize) -> Option<&'a [u8]> {
        let part = self.parts.get(part_index)?;
        Some(&self.raw[part.body.clone()])
    }

    /// Streams decoded bytes to `sink`; after an error, discard or roll back sink output and
    /// discard the budget, which may include bytes processed before the error.
    pub fn decode_part_to<W: Write>(
        &self,
        part_index: usize,
        is_attachment: bool,
        budget: &mut DecodeBudget,
        sink: &mut W,
    ) -> Result<(), DecodeError> {
        self.decode_part_to_with_diagnostics(part_index, is_attachment, budget, sink)
            .map(|_| ())
    }

    /// Decodes a leaf part and reports bounded transfer/charset observations. Diagnostics are
    /// returned only on success; discard both sink output and budget after any error.
    pub fn decode_part_to_with_diagnostics<W: Write>(
        &self,
        part_index: usize,
        is_attachment: bool,
        budget: &mut DecodeBudget,
        sink: &mut W,
    ) -> Result<DecodeDiagnostics, DecodeError> {
        let mut diagnostics = DecodeDiagnostics::default();
        self.decode_part_to_with_limits(
            part_index,
            is_attachment,
            budget,
            sink,
            DecodeLimits {
                decoded: MAX_DECODED_BYTES,
                attachment: MAX_ATTACHMENT_BYTES,
            },
            &mut diagnostics,
        )?;
        Ok(diagnostics)
    }

    /// Decodes a text or HTML part as strict UTF-8. Missing charset defaults to UTF-8;
    /// unsupported labels and malformed byte sequences return errors without replacement.
    /// After an error, discard or roll back sink output and discard the budget, which may include
    /// bytes processed before the error.
    pub fn decode_text_part_to<W: Write>(
        &self,
        part_index: usize,
        is_attachment: bool,
        budget: &mut DecodeBudget,
        sink: &mut W,
    ) -> Result<(), DecodeError> {
        self.decode_text_part_to_with_diagnostics(part_index, is_attachment, budget, sink)
            .map(|_| ())
    }

    /// Decodes text and reports bounded metadata only. Replacement-character presence may
    /// originate in valid source text; it is not evidence of a lossy conversion.
    pub fn decode_text_part_to_with_diagnostics<W: Write>(
        &self,
        part_index: usize,
        is_attachment: bool,
        budget: &mut DecodeBudget,
        sink: &mut W,
    ) -> Result<DecodeDiagnostics, DecodeError> {
        let mut diagnostics = DecodeDiagnostics::default();
        self.decode_text_part_to_with_limits(
            part_index,
            is_attachment,
            budget,
            sink,
            DecodeLimits {
                decoded: MAX_DECODED_BYTES,
                attachment: MAX_ATTACHMENT_BYTES,
            },
            &mut diagnostics,
        )?;
        Ok(diagnostics)
    }

    fn decode_text_part_to_with_limits<W: Write>(
        &self,
        part_index: usize,
        is_attachment: bool,
        budget: &mut DecodeBudget,
        sink: &mut W,
        limits: DecodeLimits,
        diagnostics: &mut DecodeDiagnostics,
    ) -> Result<(), DecodeError> {
        let part = self
            .parts
            .get(part_index)
            .ok_or(DecodeError::InvalidPartIndex)?;
        if !part.is_text {
            return Err(DecodeError::NonTextPart);
        }
        let encoding = match part.charset.as_deref() {
            Some(label) => {
                Encoding::for_label_no_replacement(label).ok_or(DecodeError::UnsupportedCharset)?
            }
            None => {
                diagnostics.charset_defaulted_to_utf8 = true;
                encoding_rs::UTF_8
            }
        };
        let body = &self.raw[part.body.clone()];
        if part.transfer_encoding == TransferEncoding::QuotedPrintable {
            diagnose_quoted_printable(body, diagnostics);
        }
        let mut output =
            CharsetBudgetedWriter::new(sink, budget, encoding, is_attachment, limits, diagnostics);
        match part.transfer_encoding {
            TransferEncoding::SevenBit => {
                if body.iter().any(|byte| *byte > 0x7f) {
                    return Err(DecodeError::MalformedTransferEncoding);
                }
                output.extend(body)?;
            }
            TransferEncoding::EightBit | TransferEncoding::Binary => output.extend(body)?,
            TransferEncoding::Base64 => decode_base64(body, &mut output)?,
            TransferEncoding::QuotedPrintable => decode_quoted_printable(body, &mut output)?,
            TransferEncoding::Other => return Err(DecodeError::UnsupportedTransferEncoding),
        }
        output.finish()
    }

    /// Decodes a message/rfc822 part's transfer encoding for a subsequent
    /// `parse_nested` call. The caller must share a `StructureBudget` across
    /// parent and nested parses and discard the output on any failure.
    pub fn decode_encapsulated_part_to<W: Write>(
        &self,
        part_index: usize,
        is_attachment: bool,
        budget: &mut DecodeBudget,
        sink: &mut W,
    ) -> Result<(), DecodeError> {
        let part = self
            .parts
            .get(part_index)
            .ok_or(DecodeError::InvalidPartIndex)?;
        if part.kind != MimePartKind::EncapsulatedMessage {
            return Err(DecodeError::NotEncapsulatedMessage);
        }
        self.decode_part_to(part_index, is_attachment, budget, sink)
    }

    fn decode_part_to_with_limits<W: Write>(
        &self,
        part_index: usize,
        is_attachment: bool,
        budget: &mut DecodeBudget,
        sink: &mut W,
        limits: DecodeLimits,
        diagnostics: &mut DecodeDiagnostics,
    ) -> Result<(), DecodeError> {
        let part = self
            .parts
            .get(part_index)
            .ok_or(DecodeError::InvalidPartIndex)?;
        if part.kind == MimePartKind::Multipart {
            return Err(DecodeError::MultipartPart);
        }

        let body = &self.raw[part.body.clone()];
        if part.transfer_encoding == TransferEncoding::QuotedPrintable {
            diagnose_quoted_printable(body, diagnostics);
        }
        let mut output = BudgetedWriter::new(sink, budget, is_attachment, limits);
        match part.transfer_encoding {
            TransferEncoding::SevenBit => {
                if body.iter().any(|byte| *byte > 0x7f) {
                    return Err(DecodeError::MalformedTransferEncoding);
                }
                output.extend(body)?;
            }
            TransferEncoding::EightBit | TransferEncoding::Binary => output.extend(body)?,
            TransferEncoding::Base64 => decode_base64(body, &mut output)?,
            TransferEncoding::QuotedPrintable => decode_quoted_printable(body, &mut output)?,
            TransferEncoding::Other => return Err(DecodeError::UnsupportedTransferEncoding),
        }
        output.finish()
    }
}

impl MimePart {
    pub fn header_range(&self) -> Range<usize> {
        self.headers.clone()
    }

    pub fn body_range(&self) -> Range<usize> {
        self.body.clone()
    }

    pub fn parent(&self) -> Option<usize> {
        self.parent
    }

    pub fn nesting_depth(&self) -> usize {
        self.nesting_depth
    }

    pub fn kind(&self) -> MimePartKind {
        self.kind
    }

    pub fn transfer_encoding(&self) -> TransferEncoding {
        self.transfer_encoding
    }

    pub fn charset(&self) -> Option<&[u8]> {
        self.charset.as_deref()
    }
}

impl MultipartFrame {
    fn next_part(&mut self, raw: &[u8]) -> Result<Option<Range<usize>>, ParseError> {
        if self.closing_seen {
            return Ok(None);
        }

        loop {
            let delimiter =
                Header::find_boundary(raw, self.search_from, self.body.end, &self.boundary);
            let Some(delimiter) = delimiter else {
                return Err(ParseError::IncompleteMultipart);
            };
            self.search_from = delimiter.after_line;

            let Some(part_start) = self.current_part_start else {
                if delimiter.closing {
                    self.closing_seen = true;
                    return Ok(None);
                }
                self.current_part_start = Some(delimiter.after_line);
                continue;
            };

            let part_end =
                Header::trim_preceding_line_ending(raw, part_start, delimiter.line_start);
            if delimiter.closing {
                self.closing_seen = true;
                self.current_part_start = None;
            } else {
                self.current_part_start = Some(delimiter.after_line);
            }
            return Ok(Some(part_start..part_end));
        }
    }
}

impl<'a> Header<'a> {
    pub fn name(&self) -> &'a [u8] {
        self.name
    }

    fn transfer_encoding(message: &Message<'_>) -> Result<TransferEncoding, ParseError> {
        let mut selected = None;
        for header in message.headers() {
            let header = header?;
            if header
                .name
                .eq_ignore_ascii_case(b"content-transfer-encoding")
            {
                if selected.is_some() {
                    return Err(ParseError::InvalidTransferEncoding);
                }
                let value = header.unfolded_value();
                let value = trim_ascii_whitespace(&value);
                let encoding = if value.eq_ignore_ascii_case(b"7bit") {
                    TransferEncoding::SevenBit
                } else if value.eq_ignore_ascii_case(b"8bit") {
                    TransferEncoding::EightBit
                } else if value.eq_ignore_ascii_case(b"binary") {
                    TransferEncoding::Binary
                } else if value.eq_ignore_ascii_case(b"base64") {
                    TransferEncoding::Base64
                } else if value.eq_ignore_ascii_case(b"quoted-printable") {
                    TransferEncoding::QuotedPrintable
                } else if !value.is_empty() && value.iter().copied().all(is_field_name_byte) {
                    TransferEncoding::Other
                } else {
                    return Err(ParseError::InvalidTransferEncoding);
                };
                selected = Some(encoding);
            }
        }
        Ok(selected.unwrap_or(TransferEncoding::SevenBit))
    }

    fn content_type(message: &Message<'_>) -> Result<Option<ContentType>, ParseError> {
        let mut selected = None;
        for header in message.headers() {
            let header = header?;
            if header.name.eq_ignore_ascii_case(b"content-type") {
                if selected.is_some() {
                    return Err(ParseError::InvalidContentType);
                }
                selected = Some(Self::parse_content_type(&header.unfolded_value())?);
            }
        }
        let Some(ContentType {
            media_type,
            boundary,
            charset,
        }) = selected
        else {
            return Ok(None);
        };
        let is_multipart = media_type
            .iter()
            .position(|byte| *byte == b'/')
            .is_some_and(|slash| media_type[..slash].eq_ignore_ascii_case(b"multipart"));
        if is_multipart {
            let boundary = boundary.ok_or(ParseError::InvalidBoundary)?;
            Self::validate_boundary(&boundary)?;
            Ok(Some(ContentType {
                media_type: b"multipart".to_vec(),
                boundary: Some(boundary),
                charset,
            }))
        } else {
            Ok(Some(ContentType {
                media_type,
                boundary,
                charset,
            }))
        }
    }

    fn parse_content_type(value: &[u8]) -> Result<ContentType, ParseError> {
        let mut cursor = 0usize;
        while value.get(cursor).is_some_and(u8::is_ascii_whitespace) {
            cursor += 1;
        }
        let media_start = cursor;
        while value.get(cursor).is_some_and(|byte| *byte != b';') {
            cursor += 1;
        }
        let media_end = value[media_start..cursor]
            .iter()
            .rposition(|byte| !byte.is_ascii_whitespace())
            .map_or(media_start, |offset| media_start + offset + 1);
        let media_type = value[media_start..media_end].to_vec();
        let mut media_type_parts = media_type.split(|byte| *byte == b'/');
        let top_level = media_type_parts.next().unwrap_or_default();
        let subtype = media_type_parts.next().unwrap_or_default();
        if top_level.is_empty()
            || subtype.is_empty()
            || media_type_parts.next().is_some()
            || !top_level.iter().copied().all(is_field_name_byte)
            || !subtype.iter().copied().all(is_field_name_byte)
        {
            return Err(ParseError::InvalidContentType);
        }

        let mut boundary = None;
        let mut charset = None;
        while cursor < value.len() {
            cursor += 1;
            while value.get(cursor).is_some_and(u8::is_ascii_whitespace) {
                cursor += 1;
            }
            let name_start = cursor;
            while value
                .get(cursor)
                .is_some_and(|byte| *byte != b'=' && *byte != b';')
            {
                cursor += 1;
            }
            if value.get(cursor) != Some(&b'=') {
                while value.get(cursor).is_some_and(|byte| *byte != b';') {
                    cursor += 1;
                }
                continue;
            }
            let name_end = value[name_start..cursor]
                .iter()
                .rposition(|byte| !byte.is_ascii_whitespace())
                .map_or(name_start, |offset| name_start + offset + 1);
            cursor += 1;
            while value.get(cursor).is_some_and(u8::is_ascii_whitespace) {
                cursor += 1;
            }

            let parameter = if value.get(cursor) == Some(&b'"') {
                cursor += 1;
                let mut parameter = Vec::new();
                let mut closed = false;
                while let Some(byte) = value.get(cursor).copied() {
                    cursor += 1;
                    match byte {
                        b'\\' => {
                            let escaped = value
                                .get(cursor)
                                .copied()
                                .ok_or(ParseError::InvalidBoundary)?;
                            cursor += 1;
                            parameter.push(escaped);
                        }
                        b'"' => {
                            closed = true;
                            break;
                        }
                        _ => parameter.push(byte),
                    }
                    if parameter.len() > 70 {
                        return Err(ParseError::InvalidBoundary);
                    }
                }
                if !closed {
                    return Err(ParseError::InvalidBoundary);
                }
                parameter
            } else {
                let start = cursor;
                while value.get(cursor).is_some_and(|byte| *byte != b';') {
                    cursor += 1;
                }
                let end = value[start..cursor]
                    .iter()
                    .rposition(|byte| !byte.is_ascii_whitespace())
                    .map_or(start, |offset| start + offset + 1);
                value[start..end].to_vec()
            };
            while value.get(cursor).is_some_and(u8::is_ascii_whitespace) {
                cursor += 1;
            }
            if cursor < value.len() && value[cursor] != b';' {
                return Err(ParseError::InvalidContentType);
            }

            let name = &value[name_start..name_end];
            if name.eq_ignore_ascii_case(b"boundary") {
                if boundary.replace(parameter).is_some() {
                    return Err(ParseError::InvalidBoundary);
                }
            } else if name.eq_ignore_ascii_case(b"charset")
                && (parameter.is_empty()
                    || !parameter
                        .iter()
                        .copied()
                        .all(|byte| byte.is_ascii() && is_field_name_byte(byte))
                    || charset.replace(parameter).is_some())
            {
                return Err(ParseError::InvalidContentType);
            }
        }
        Ok(ContentType {
            media_type,
            boundary,
            charset,
        })
    }

    fn validate_boundary(boundary: &[u8]) -> Result<(), ParseError> {
        if boundary.is_empty()
            || boundary.len() > 70
            || boundary.last().is_some_and(u8::is_ascii_whitespace)
            || !boundary.iter().copied().all(|byte| {
                byte.is_ascii_alphanumeric()
                    || matches!(
                        byte,
                        b'\''
                            | b'('
                            | b')'
                            | b'+'
                            | b'_'
                            | b','
                            | b'-'
                            | b'.'
                            | b'/'
                            | b':'
                            | b'='
                            | b'?'
                            | b' '
                    )
            })
        {
            return Err(ParseError::InvalidBoundary);
        }
        Ok(())
    }

    fn find_boundary(raw: &[u8], start: usize, end: usize, boundary: &[u8]) -> Option<Delimiter> {
        let mut line_start = start;
        while line_start < end {
            let remaining = &raw[line_start..end];
            let newline = remaining.iter().position(|byte| *byte == b'\n');
            let line_after = newline.map_or(end, |offset| line_start + offset + 1);
            let mut line_end = newline.map_or(end, |offset| line_start + offset);
            if line_end > line_start && raw[line_end - 1] == b'\r' {
                line_end -= 1;
            }
            let line = &raw[line_start..line_end];
            let marker = boundary.len().checked_add(2)?;
            if line.len() >= marker && &line[..2] == b"--" && &line[2..marker] == boundary {
                let suffix = &line[marker..];
                let (closing, padding) = if suffix.starts_with(b"--") {
                    (true, &suffix[2..])
                } else {
                    (false, suffix)
                };
                if padding.iter().all(|byte| *byte == b' ' || *byte == b'\t') {
                    return Some(Delimiter {
                        line_start,
                        after_line: line_after,
                        closing,
                    });
                }
            }
            if newline.is_none() {
                break;
            }
            line_start = line_after;
        }
        None
    }

    fn trim_preceding_line_ending(raw: &[u8], start: usize, end: usize) -> usize {
        let mut trimmed = end;
        if trimmed > start && raw[trimmed - 1] == b'\n' {
            trimmed -= 1;
            if trimmed > start && raw[trimmed - 1] == b'\r' {
                trimmed -= 1;
            }
        }
        trimmed
    }

    pub fn raw_value(&self) -> &'a [u8] {
        self.raw_value
    }

    pub fn unfolded_value(&self) -> Vec<u8> {
        let mut unfolded =
            Vec::with_capacity(self.raw_value.len().min(MAX_UNFOLDED_HEADER_VALUE_BYTES));
        let mut cursor = 0usize;

        while cursor < self.raw_value.len() {
            let remaining = &self.raw_value[cursor..];
            let line_end = remaining
                .iter()
                .position(|byte| *byte == b'\r' || *byte == b'\n')
                .unwrap_or(remaining.len());
            let line = &remaining[..line_end];

            unfolded.extend_from_slice(line);

            cursor += line_end;
            if cursor == self.raw_value.len() {
                break;
            }
            if self.raw_value[cursor] == b'\r' {
                cursor += 2;
            } else {
                cursor += 1;
            }
        }

        unfolded
    }
}

impl<'a> Iterator for Headers<'a> {
    type Item = Result<Header<'a>, ParseError>;

    fn next(&mut self) -> Option<Self::Item> {
        while self.cursor < self.headers_end {
            let start = self.cursor;
            let line = match read_line(self.raw, start) {
                Ok(line) => line,
                Err(error) => {
                    self.cursor = self.headers_end;
                    return Some(Err(error));
                }
            };
            if start == line.content_end {
                self.cursor = line.next;
                return None;
            }
            if self.raw[start] == b' ' || self.raw[start] == b'\t' {
                self.cursor = line.next;
                continue;
            }

            let Some(colon_offset) = self.raw[start..line.content_end]
                .iter()
                .position(|byte| *byte == b':')
            else {
                self.cursor = self.headers_end;
                return Some(Err(ParseError::InvalidHeaderName));
            };
            let colon = start + colon_offset;
            let name = &self.raw[start..colon];
            let value_start = colon + 1;
            let mut value_end = line.content_end;
            self.cursor = line.next;

            loop {
                if self.cursor >= self.headers_end {
                    break;
                }
                let continuation = match read_line(self.raw, self.cursor) {
                    Ok(line) => line,
                    Err(error) => {
                        self.cursor = self.headers_end;
                        return Some(Err(error));
                    }
                };
                if self.cursor == continuation.content_end {
                    break;
                }
                let byte = self.raw[self.cursor];
                if byte != b' ' && byte != b'\t' {
                    break;
                }
                value_end = continuation.content_end;
                self.cursor = continuation.next;
            }

            return Some(Ok(Header {
                name,
                raw_value: &self.raw[value_start..value_end],
            }));
        }
        None
    }
}

fn read_line(raw: &[u8], start: usize) -> Result<Line, ParseError> {
    if start > raw.len() {
        return Err(ParseError::MissingHeaderBodySeparator);
    }
    let scan_end = start
        .saturating_add(MAX_PHYSICAL_HEADER_LINE_BYTES + 2)
        .min(raw.len());
    let newline = raw[start..scan_end].iter().position(|byte| *byte == b'\n');
    if newline.is_none() && raw.len() - start > MAX_PHYSICAL_HEADER_LINE_BYTES {
        return Err(ParseError::HeaderLineTooLong);
    }
    let (content_end, next) = match newline {
        Some(offset) => {
            let lf = start + offset;
            if lf > start && raw[lf - 1] == b'\r' {
                (lf - 1, lf + 1)
            } else {
                (lf, lf + 1)
            }
        }
        None => (raw.len(), raw.len()),
    };
    if raw[start..content_end].contains(&b'\r') {
        return Err(ParseError::InvalidLineEnding);
    }
    if content_end - start > MAX_PHYSICAL_HEADER_LINE_BYTES {
        return Err(ParseError::HeaderLineTooLong);
    }
    if next == raw.len() && newline.is_none() {
        return Err(ParseError::MissingHeaderBodySeparator);
    }
    Ok(Line { content_end, next })
}

fn is_field_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
        || matches!(
            byte,
            b'!' | b'#'
                | b'$'
                | b'%'
                | b'&'
                | b'\''
                | b'*'
                | b'+'
                | b'-'
                | b'.'
                | b'^'
                | b'_'
                | b'`'
                | b'|'
                | b'~'
        )
}

fn trim_ascii_whitespace(mut value: &[u8]) -> &[u8] {
    while value.first().is_some_and(u8::is_ascii_whitespace) {
        value = &value[1..];
    }
    while value.last().is_some_and(u8::is_ascii_whitespace) {
        value = &value[..value.len() - 1];
    }
    value
}

fn decode_base64<O: DecodeOutput>(input: &[u8], output: &mut O) -> Result<(), DecodeError> {
    let mut quartet = [0u8; 4];
    let mut quartet_len = 0usize;
    let mut padded = false;

    for byte in input.iter().copied() {
        if matches!(byte, b' ' | b'\t' | b'\r' | b'\n') {
            continue;
        }
        if padded {
            return Err(DecodeError::MalformedTransferEncoding);
        }
        if byte != b'=' && base64_value(byte).is_none() {
            return Err(DecodeError::MalformedTransferEncoding);
        }
        quartet[quartet_len] = byte;
        quartet_len += 1;
        if quartet_len != 4 {
            continue;
        }

        let first = base64_value(quartet[0]).ok_or(DecodeError::MalformedTransferEncoding)?;
        let second = base64_value(quartet[1]).ok_or(DecodeError::MalformedTransferEncoding)?;
        let third = if quartet[2] == b'=' {
            None
        } else {
            Some(base64_value(quartet[2]).ok_or(DecodeError::MalformedTransferEncoding)?)
        };
        let fourth = if quartet[3] == b'=' {
            None
        } else {
            Some(base64_value(quartet[3]).ok_or(DecodeError::MalformedTransferEncoding)?)
        };

        if third.is_none() && (fourth.is_some() || second & 0x0f != 0) {
            return Err(DecodeError::MalformedTransferEncoding);
        }
        if fourth.is_none() && third.is_some_and(|value| value & 0x03 != 0) {
            return Err(DecodeError::MalformedTransferEncoding);
        }

        output.push((first << 2) | (second >> 4))?;
        if let Some(third) = third {
            output.push((second << 4) | (third >> 2))?;
            if let Some(fourth) = fourth {
                output.push((third << 6) | fourth)?;
            } else {
                padded = true;
            }
        } else {
            padded = true;
        }
        quartet_len = 0;
    }

    if quartet_len != 0 {
        return Err(DecodeError::MalformedTransferEncoding);
    }
    Ok(())
}

fn base64_value(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

fn diagnose_quoted_printable(input: &[u8], diagnostics: &mut DecodeDiagnostics) {
    let mut line_start = 0usize;
    while line_start < input.len() {
        let newline = input[line_start..]
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|offset| line_start + offset);
        let mut line_end = newline.unwrap_or(input.len());
        let crlf = line_end > line_start && input[line_end - 1] == b'\r';
        if crlf {
            line_end -= 1;
        }

        if input[line_start..line_end]
            .last()
            .is_some_and(|byte| matches!(byte, b' ' | b'\t'))
        {
            diagnostics.quoted_printable_trailing_whitespace_unencoded = true;
        }
        if newline.is_some() && !crlf && line_end > line_start && input[line_end - 1] == b'=' {
            diagnostics.quoted_printable_soft_break_lf_only = true;
        }

        let Some(newline) = newline else {
            break;
        };
        line_start = newline + 1;
    }
}

fn decode_quoted_printable<O: DecodeOutput>(
    input: &[u8],
    output: &mut O,
) -> Result<(), DecodeError> {
    let mut cursor = 0usize;
    while cursor < input.len() {
        if input[cursor] != b'=' {
            output.push(input[cursor])?;
            cursor += 1;
            continue;
        }

        match input.get(cursor + 1..) {
            Some([b'\r', b'\n', ..]) => cursor += 3,
            Some([b'\n', ..]) => cursor += 2,
            Some([high, low, ..]) => {
                let high = hex_value(*high).ok_or(DecodeError::MalformedTransferEncoding)?;
                let low = hex_value(*low).ok_or(DecodeError::MalformedTransferEncoding)?;
                output.push((high << 4) | low)?;
                cursor += 3;
            }
            _ => return Err(DecodeError::MalformedTransferEncoding),
        }
    }
    Ok(())
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scans_headers_and_keeps_body_as_a_borrowed_range() {
        let raw = b"Subject: first\r\n\t second\r\nX-Test: value\n\nbody\0bytes";
        let message = Message::parse(raw).unwrap();
        let headers: Vec<_> = message.headers().map(|header| header.unwrap()).collect();

        assert_eq!(message.header_count(), 2);
        assert_eq!(headers[0].name(), b"Subject");
        assert_eq!(headers[0].raw_value(), b" first\r\n\t second");
        assert_eq!(headers[0].unfolded_value(), b" first\t second");
        assert_eq!(headers[1].name(), b"X-Test");
        assert_eq!(headers[1].unfolded_value(), b" value");
        assert_eq!(message.body(), b"body\0bytes");
        assert_eq!(message.body(), &raw[message.body_range()]);
    }

    #[test]
    fn accepts_exact_header_limits_and_rejects_one_byte_over() {
        let mut line = vec![b'X'];
        line.extend(std::iter::repeat_n(
            b'a',
            MAX_PHYSICAL_HEADER_LINE_BYTES - 2,
        ));
        line.extend_from_slice(b":\r\n\r\nbody");
        assert_eq!(Message::parse(&line).unwrap().header_count(), 1);

        line.insert(MAX_PHYSICAL_HEADER_LINE_BYTES - 1, b'a');
        assert!(matches!(
            Message::parse(&line),
            Err(ParseError::HeaderLineTooLong)
        ));

        for value_size in [
            MAX_UNFOLDED_HEADER_VALUE_BYTES,
            MAX_UNFOLDED_HEADER_VALUE_BYTES + 1,
        ] {
            let raw = folded_header(value_size);
            match Message::parse(&raw) {
                Ok(message) => {
                    assert_eq!(value_size, MAX_UNFOLDED_HEADER_VALUE_BYTES);
                    let header = message.headers().next().unwrap().unwrap();
                    assert_eq!(header.unfolded_value().len(), value_size);
                }
                Err(error) => {
                    assert_eq!(value_size, MAX_UNFOLDED_HEADER_VALUE_BYTES + 1);
                    assert_eq!(error, ParseError::HeaderValueTooLarge);
                }
            }
        }
    }

    #[test]
    fn enforces_total_header_block_limit_before_building_header_objects() {
        let at_limit = header_block_of_size(MAX_HEADER_BLOCK_BYTES);
        assert_eq!(Message::parse(&at_limit).unwrap().header_count(), 1049);

        let over_limit = header_block_of_size(MAX_HEADER_BLOCK_BYTES + 1);
        assert!(matches!(
            Message::parse(&over_limit),
            Err(ParseError::HeaderBlockTooLarge)
        ));
    }

    #[test]
    fn rejects_malformed_headers_and_missing_separator_explicitly() {
        for (raw, expected) in [
            (
                &b" folded: no\r\n\r\nbody"[..],
                ParseError::ContinuationWithoutHeader,
            ),
            (
                &b"Subject: value\rbare-cr\r\n\r\nbody"[..],
                ParseError::InvalidLineEnding,
            ),
            (
                &b"Bad Name: value\r\n\r\nbody"[..],
                ParseError::InvalidHeaderName,
            ),
            (
                &b"Subject: no separator"[..],
                ParseError::MissingHeaderBodySeparator,
            ),
        ] {
            assert!(matches!(Message::parse(raw), Err(error) if error == expected));
        }
    }

    #[test]
    fn rejects_raw_input_over_the_shared_limit_before_scanning() {
        let raw = vec![b'x'; MAX_RAW_BYTES + 1];
        assert!(matches!(Message::parse(&raw), Err(ParseError::RawTooLarge)));
    }

    #[test]
    fn scans_multipart_parts_as_borrowed_ranges_and_ignores_boundary_prefixes() {
        let raw = b"Content-Type: multipart/mixed; boundary=\"slice-boundary\"\r\n\r\npreamble\r\n--slice-boundary\r\nContent-Type: text/plain\r\n\r\nfirst\r\n--slice-boundary-extra\r\nstill first\r\n--slice-boundary\r\nContent-Type: application/octet-stream\r\n\r\nsecond\r\n--slice-boundary--\r\nepilogue";
        let message = MimeDocument::parse(raw).unwrap();
        let parts = message.parts();

        assert_eq!(parts.len(), 3);
        assert_eq!(parts[0].kind(), MimePartKind::Multipart);
        assert_eq!(parts[0].parent(), None);
        assert_eq!(parts[1].parent(), Some(0));
        assert_eq!(parts[2].parent(), Some(0));
        assert!(
            message
                .part_headers(1)
                .unwrap()
                .starts_with(b"Content-Type: text/plain")
        );
        assert_eq!(
            message.part_body(1).unwrap(),
            b"first\r\n--slice-boundary-extra\r\nstill first"
        );
        assert_eq!(message.part_body(2).unwrap(), b"second");
        assert_eq!(message.part_body(3), None);
        assert_eq!(message.raw(), raw);
    }

    #[test]
    fn counts_multipart_parts_before_exceeding_the_cap() {
        for (child_parts, expected) in [
            (MAX_MIME_PARTS - 1, None),
            (MAX_MIME_PARTS, Some(ParseError::TooManyParts)),
        ] {
            let raw = multipart_with_leaf_parts(child_parts);
            match MimeDocument::parse(&raw) {
                Ok(message) => {
                    assert_eq!(expected, None);
                    assert_eq!(message.parts().len(), MAX_MIME_PARTS);
                }
                Err(error) => assert_eq!(Some(error), expected),
            }
        }
    }

    #[test]
    fn rejects_multipart_nesting_over_the_cap_and_accepts_the_exact_limit() {
        for (depth, expected_error) in [
            (MAX_MIME_NESTING, None),
            (MAX_MIME_NESTING + 1, Some(ParseError::NestingTooDeep)),
        ] {
            let raw = nested_multipart(depth);
            match MimeDocument::parse(&raw) {
                Ok(message) => {
                    assert_eq!(expected_error, None);
                    assert_eq!(message.parts().last().unwrap().nesting_depth(), depth);
                    assert_eq!(message.parts().len(), depth + 1);
                }
                Err(error) => assert_eq!(Some(error), expected_error),
            }
        }
    }

    #[test]
    fn counts_encapsulated_messages_toward_the_same_nesting_budget() {
        for (depth, expected_error) in [
            (MAX_MIME_NESTING, None),
            (MAX_MIME_NESTING + 1, Some(ParseError::NestingTooDeep)),
        ] {
            let raw = nested_rfc822(depth);
            match MimeDocument::parse(&raw) {
                Ok(message) => {
                    assert_eq!(expected_error, None);
                    assert_eq!(message.parts().len(), depth + 1);
                    assert_eq!(message.parts()[0].kind(), MimePartKind::EncapsulatedMessage);
                }
                Err(error) => assert_eq!(Some(error), expected_error),
            }
        }
    }

    #[test]
    fn malformed_multipart_is_not_returned_as_a_complete_document() {
        let raw = b"Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\nbody\r\n";
        assert!(matches!(
            MimeDocument::parse(raw),
            Err(ParseError::IncompleteMultipart)
        ));

        let invalid = b"Content-Type: multipart/mixed; boundary=\"bad;value\"\r\n\r\n--bad\r\n";
        assert!(matches!(
            MimeDocument::parse(invalid),
            Err(ParseError::InvalidBoundary)
        ));

        for raw in [
            &b"Content-Type: multipart\r\n\r\n--x--\r\n"[..],
            &b"Content-Type: multipart/mixed; boundary=x\"junk\r\n\r\n--x--\r\n"[..],
            &b"Content-Type: multipart/mixed; boundary=x\r\nContent-Type: text/plain\r\n\r\n--x--\r\n"[..],
        ] {
            assert!(matches!(
                MimeDocument::parse(raw),
                Err(ParseError::InvalidContentType | ParseError::InvalidBoundary)
            ));
        }
    }

    #[test]
    fn decodes_base64_and_quoted_printable_without_replacing_malformed_input() {
        let base64 =
            MimeDocument::parse(b"Content-Transfer-Encoding: base64\r\n\r\nSGVs\r\nbG8=").unwrap();
        let mut decoded = Vec::new();
        base64
            .decode_part_to(0, false, &mut DecodeBudget::new(), &mut decoded)
            .unwrap();
        assert_eq!(decoded, b"Hello");

        let quoted_printable = MimeDocument::parse(
            b"Content-Transfer-Encoding: quoted-printable\r\n\r\nhello=20world=\r\nnext=21",
        )
        .unwrap();
        let mut decoded = Vec::new();
        quoted_printable
            .decode_part_to(0, false, &mut DecodeBudget::new(), &mut decoded)
            .unwrap();
        assert_eq!(decoded, b"hello worldnext!");

        for (encoding, body) in [
            ("base64", &b"SGVsbG8=!"[..]),
            ("base64", &b"SGVsbG8"[..]),
            ("base64", &b"Zh=="[..]),
            ("quoted-printable", &b"abc="[..]),
            ("quoted-printable", &b"abc=Q"[..]),
            ("quoted-printable", &b"abc=0G"[..]),
        ] {
            let mut raw = format!("Content-Transfer-Encoding: {encoding}\r\n\r\n").into_bytes();
            raw.extend_from_slice(body);
            let message = MimeDocument::parse(&raw).unwrap();
            let mut decoded = Vec::new();
            assert_eq!(
                message.decode_part_to(0, false, &mut DecodeBudget::new(), &mut decoded),
                Err(DecodeError::MalformedTransferEncoding)
            );
        }
    }

    #[test]
    fn enforces_cumulative_and_attachment_budgets_before_sink_writes() {
        let first = MimeDocument::parse(b"\r\nabc").unwrap();
        let second = MimeDocument::parse(b"\r\nd").unwrap();
        let limits = DecodeLimits {
            decoded: 3,
            attachment: 2,
        };
        let mut budget = DecodeBudget::new();
        let mut decoded = Vec::new();
        first
            .decode_part_to_with_limits(
                0,
                false,
                &mut budget,
                &mut decoded,
                limits,
                &mut DecodeDiagnostics::default(),
            )
            .unwrap();
        assert_eq!(decoded, b"abc");
        assert_eq!(budget.decoded_bytes(), 3);

        let mut over_budget = Vec::new();
        assert_eq!(
            second.decode_part_to_with_limits(
                0,
                false,
                &mut budget,
                &mut over_budget,
                limits,
                &mut DecodeDiagnostics::default(),
            ),
            Err(DecodeError::DecodedTooLarge)
        );
        assert!(over_budget.is_empty());
        assert_eq!(budget.decoded_bytes(), 3);

        let attachment = MimeDocument::parse(b"\r\nabc").unwrap();
        let mut attachment_budget = DecodeBudget::new();
        let mut attachment_output = Vec::new();
        assert_eq!(
            attachment.decode_part_to_with_limits(
                0,
                true,
                &mut attachment_budget,
                &mut attachment_output,
                limits,
                &mut DecodeDiagnostics::default(),
            ),
            Err(DecodeError::AttachmentTooLarge)
        );
        assert!(attachment_output.is_empty());
        assert_eq!(attachment_budget.decoded_bytes(), 2);
    }

    #[test]
    fn reports_unsupported_encodings_and_rejects_invalid_transfer_headers() {
        let unsupported =
            MimeDocument::parse(b"Content-Transfer-Encoding: x-custom\r\n\r\nbody").unwrap();
        assert_eq!(
            unsupported.parts()[0].transfer_encoding(),
            TransferEncoding::Other
        );
        assert_eq!(
            unsupported.decode_part_to(0, false, &mut DecodeBudget::new(), &mut Vec::new()),
            Err(DecodeError::UnsupportedTransferEncoding)
        );

        for raw in [
            &b"Content-Transfer-Encoding: base64; extra\r\n\r\nAA=="[..],
            &b"Content-Transfer-Encoding: base64\r\nContent-Transfer-Encoding: 7bit\r\n\r\nAA=="[..],
        ] {
            assert!(matches!(
                MimeDocument::parse(raw),
                Err(ParseError::InvalidTransferEncoding)
            ));
        }

        let high_bit = MimeDocument::parse(b"Content-Transfer-Encoding: 7bit\r\n\r\n\xff").unwrap();
        assert_eq!(
            high_bit.decode_part_to(0, false, &mut DecodeBudget::new(), &mut Vec::new()),
            Err(DecodeError::MalformedTransferEncoding)
        );
    }

    #[test]
    fn rejects_decoding_multipart_containers() {
        let multipart =
            MimeDocument::parse(b"Content-Type: multipart/mixed; boundary=x\r\n\r\n--x--\r\n")
                .unwrap();
        assert_eq!(
            multipart.decode_part_to(0, false, &mut DecodeBudget::new(), &mut Vec::new()),
            Err(DecodeError::MultipartPart)
        );
    }

    #[test]
    fn decodes_declared_text_charsets_incrementally_and_rejects_malformed_bytes() {
        let mut raw =
            b"Content-Type: text/plain; charset=shift_jis\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
                .to_vec();
        raw.extend(std::iter::repeat_n(b'a', 1023));
        raw.extend_from_slice(&[0x93, 0xfa, 0x96, 0x7b, 0x8c, 0xea]);
        let message = MimeDocument::parse(&raw).unwrap();
        assert_eq!(message.parts()[0].charset(), Some(&b"shift_jis"[..]));
        let mut decoded = Vec::new();
        message
            .decode_text_part_to(0, false, &mut DecodeBudget::new(), &mut decoded)
            .unwrap();
        assert_eq!(
            &decoded[1023..],
            "日本語".as_bytes(),
            "a multibyte sequence straddles the fixed input-buffer boundary"
        );

        let encoded = MimeDocument::parse(
            b"Content-Type: text/plain; charset=windows-1252\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n=80",
        )
        .unwrap();
        let mut decoded = Vec::new();
        let mut budget = DecodeBudget::new();
        encoded
            .decode_text_part_to(0, false, &mut budget, &mut decoded)
            .unwrap();
        assert_eq!(decoded, "€".as_bytes());
        assert_eq!(budget.decoded_bytes(), 4);

        for (charset, body) in [
            ("utf-8", &b"bad \xff"[..]),
            ("shift_jis", &b"\x82"[..]),
            ("utf-16le", &b"\x41"[..]),
        ] {
            let mut raw = format!(
                "Content-Type: text/plain; charset={charset}\r\nContent-Transfer-Encoding: 8bit\r\n\r\n"
            )
            .into_bytes();
            raw.extend_from_slice(body);
            let message = MimeDocument::parse(&raw).unwrap();
            assert!(matches!(
                message.decode_text_part_to(0, false, &mut DecodeBudget::new(), &mut Vec::new()),
                Err(DecodeError::MalformedCharset)
            ));
        }
    }

    #[test]
    fn decodes_and_scans_an_encapsulated_message_with_shared_budgets() {
        let raw = b"Content-Type: message/rfc822\r\nContent-Transfer-Encoding: base64\r\n\r\nQ29udGVudC1UeXBlOiB0ZXh0L3BsYWluOyBjaGFyc2V0PXV0Zi04DQoNCk5lc3RlZCBib2R5";
        let parent = MimeDocument::parse(raw).unwrap();
        assert_eq!(parent.parts()[0].kind(), MimePartKind::EncapsulatedMessage);

        let mut decoded_message = Vec::new();
        let mut decode_budget = DecodeBudget::new();
        parent
            .decode_encapsulated_part_to(0, false, &mut decode_budget, &mut decoded_message)
            .unwrap();
        assert_eq!(
            decoded_message,
            b"Content-Type: text/plain; charset=utf-8\r\n\r\nNested body"
        );

        let mut structure_budget = StructureBudget::new();
        let parent = MimeDocument::parse_nested(raw, 0, &mut structure_budget).unwrap();
        let nested_depth = parent.parts()[0].nesting_depth() + 1;
        let nested =
            MimeDocument::parse_nested(&decoded_message, nested_depth, &mut structure_budget)
                .unwrap();
        assert_eq!(structure_budget.parts(), 2);
        assert_eq!(
            structure_budget.header_bytes(),
            parent.parts()[0].header_range().len() + nested.parts()[0].header_range().len()
        );
        assert_eq!(nested.parts()[0].nesting_depth(), 1);
        let mut nested_body = Vec::new();
        nested
            .decode_text_part_to(0, false, &mut decode_budget, &mut nested_body)
            .unwrap();
        assert_eq!(nested_body, b"Nested body");

        let plain_part =
            MimeDocument::parse(b"Content-Type: text/plain\r\n\r\nnot a message").unwrap();
        assert!(matches!(
            plain_part.decode_encapsulated_part_to(
                0,
                false,
                &mut DecodeBudget::new(),
                &mut Vec::new()
            ),
            Err(DecodeError::NotEncapsulatedMessage)
        ));
    }

    #[test]
    fn nested_parses_share_part_header_and_depth_budgets() {
        let parent_raw =
            b"Content-Type: message/rfc822\r\nContent-Transfer-Encoding: base64\r\n\r\ncGxhY2Vob2xkZXI=";
        let nested_raw = b"X: y\r\n\r\nleaf";

        let mut parts = StructureBudget {
            parts: MAX_MIME_PARTS - 2,
            header_bytes: 0,
        };
        let parent = MimeDocument::parse_nested(parent_raw, 0, &mut parts).unwrap();
        assert_eq!(parent.parts()[0].kind(), MimePartKind::EncapsulatedMessage);
        assert_eq!(parts.parts(), MAX_MIME_PARTS - 1);
        let at_cap = MimeDocument::parse_nested(nested_raw, 1, &mut parts).unwrap();
        assert_eq!(at_cap.parts().len(), 1);
        assert_eq!(parts.parts(), MAX_MIME_PARTS);
        assert!(matches!(
            MimeDocument::parse_nested(nested_raw, 1, &mut parts),
            Err(ParseError::TooManyParts)
        ));

        let mut headers = StructureBudget {
            parts: 0,
            header_bytes: MAX_HEADER_BLOCK_BYTES
                - Message::parse(parent_raw)
                    .unwrap()
                    .header_block_range()
                    .len(),
        };
        MimeDocument::parse_nested(parent_raw, 0, &mut headers).unwrap();
        assert_eq!(headers.header_bytes(), MAX_HEADER_BLOCK_BYTES);
        assert!(matches!(
            MimeDocument::parse_nested(nested_raw, 1, &mut headers),
            Err(ParseError::HeaderBlockTooLarge)
        ));

        let mut depth_budget = StructureBudget::new();
        let at_limit =
            MimeDocument::parse_nested(nested_raw, MAX_MIME_NESTING, &mut depth_budget).unwrap();
        assert_eq!(at_limit.parts()[0].nesting_depth(), MAX_MIME_NESTING);
        assert!(matches!(
            MimeDocument::parse_nested(nested_raw, MAX_MIME_NESTING + 1, &mut depth_budget),
            Err(ParseError::NestingTooDeep)
        ));
    }

    #[test]
    fn text_decoding_rejects_unknown_duplicate_and_non_text_charsets() {
        let unknown =
            MimeDocument::parse(b"Content-Type: text/plain; charset=x-private-charset\r\n\r\nbody")
                .unwrap();
        assert!(matches!(
            unknown.decode_text_part_to(0, false, &mut DecodeBudget::new(), &mut Vec::new()),
            Err(DecodeError::UnsupportedCharset)
        ));

        let replacement =
            MimeDocument::parse(b"Content-Type: text/plain; charset=replacement\r\n\r\nbody")
                .unwrap();
        assert!(matches!(
            replacement.decode_text_part_to(0, false, &mut DecodeBudget::new(), &mut Vec::new()),
            Err(DecodeError::UnsupportedCharset)
        ));

        let binary =
            MimeDocument::parse(b"Content-Type: application/octet-stream\r\n\r\nbody").unwrap();
        assert!(matches!(
            binary.decode_text_part_to(0, false, &mut DecodeBudget::new(), &mut Vec::new()),
            Err(DecodeError::NonTextPart)
        ));

        for raw in [
            &b"Content-Type: text/plain; charset=utf-8; charset=shift_jis\r\n\r\nbody"[..],
            &b"Content-Type: text/plain; charset=\"\"\r\n\r\nbody"[..],
        ] {
            assert!(matches!(
                MimeDocument::parse(raw),
                Err(ParseError::InvalidContentType)
            ));
        }
    }

    #[test]
    fn reports_utf8_default_and_replacement_character_presence_without_claiming_loss() {
        let mut raw =
            b"Content-Type: text/plain\r\nContent-Transfer-Encoding: 8bit\r\n\r\n".to_vec();
        raw.extend(std::iter::repeat_n(b'a', 1023));
        raw.extend_from_slice("�".as_bytes());
        let message = MimeDocument::parse(&raw).unwrap();
        let mut decoded = Vec::new();
        let diagnostics = message
            .decode_text_part_to_with_diagnostics(0, false, &mut DecodeBudget::new(), &mut decoded)
            .unwrap();
        assert!(diagnostics.charset_defaulted_to_utf8);
        assert!(
            diagnostics.replacement_character_present,
            "{diagnostics:?}, decoded suffix: {:?}",
            &decoded[decoded.len().saturating_sub(8)..]
        );
        assert_eq!(decoded, raw[message.parts()[0].body_range()]);

        let explicit =
            MimeDocument::parse(b"Content-Type: text/plain; charset=utf-8\r\n\r\nPlain text")
                .unwrap();
        let diagnostics = explicit
            .decode_text_part_to_with_diagnostics(
                0,
                false,
                &mut DecodeBudget::new(),
                &mut Vec::new(),
            )
            .unwrap();
        assert!(!diagnostics.charset_defaulted_to_utf8);
        assert!(!diagnostics.replacement_character_present);
    }

    #[test]
    fn reports_quoted_printable_noncanonical_forms_without_rewriting_source_bytes() {
        let raw = b"Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\ntail \r\nmid\t\nsoft=\ncontinued=\r\nend ";
        let message = MimeDocument::parse(raw).unwrap();
        let mut decoded = Vec::new();
        let diagnostics = message
            .decode_text_part_to_with_diagnostics(0, false, &mut DecodeBudget::new(), &mut decoded)
            .unwrap();

        assert!(diagnostics.quoted_printable_soft_break_lf_only);
        assert!(diagnostics.quoted_printable_trailing_whitespace_unencoded);
        assert_eq!(decoded, b"tail \r\nmid\t\nsoftcontinuedend ");

        let canonical = MimeDocument::parse(
            b"Content-Transfer-Encoding: quoted-printable\r\n\r\nsoft=\r\nbreak=20",
        )
        .unwrap();
        let diagnostics = canonical
            .decode_part_to_with_diagnostics(0, false, &mut DecodeBudget::new(), &mut Vec::new())
            .unwrap();
        assert!(!diagnostics.quoted_printable_soft_break_lf_only);
        assert!(!diagnostics.quoted_printable_trailing_whitespace_unencoded);
    }

    #[test]
    fn charges_transfer_and_charset_output_before_sink_write() {
        let expanding = MimeDocument::parse(
            b"Content-Type: text/plain; charset=windows-1252\r\nContent-Transfer-Encoding: 8bit\r\n\r\n\x80",
        )
        .unwrap();
        let mut exact_output = Vec::new();
        let mut exact_budget = DecodeBudget::new();
        expanding
            .decode_text_part_to_with_limits(
                0,
                false,
                &mut exact_budget,
                &mut exact_output,
                DecodeLimits {
                    decoded: 4,
                    attachment: 3,
                },
                &mut DecodeDiagnostics::default(),
            )
            .unwrap();
        assert_eq!(exact_output, "€".as_bytes());
        assert_eq!(exact_budget.decoded_bytes(), 4);

        let mut over_output = Vec::new();
        let mut over_budget = DecodeBudget::new();
        assert!(matches!(
            expanding.decode_text_part_to_with_limits(
                0,
                false,
                &mut over_budget,
                &mut over_output,
                DecodeLimits {
                    decoded: 3,
                    attachment: 3,
                },
                &mut DecodeDiagnostics::default(),
            ),
            Err(DecodeError::DecodedTooLarge)
        ));
        assert!(over_output.is_empty());

        let identity =
            MimeDocument::parse(b"Content-Type: text/plain; charset=utf-8\r\n\r\nA").unwrap();
        let mut attachment = Vec::new();
        assert!(matches!(
            identity.decode_text_part_to_with_limits(
                0,
                true,
                &mut DecodeBudget::new(),
                &mut attachment,
                DecodeLimits {
                    decoded: 2,
                    attachment: 0,
                },
                &mut DecodeDiagnostics::default(),
            ),
            Err(DecodeError::AttachmentTooLarge)
        ));
        assert!(attachment.is_empty());
    }

    fn folded_header(value_size: usize) -> Vec<u8> {
        let mut raw = b"X:".to_vec();
        let mut remaining = value_size;
        let initial = remaining.min(MAX_PHYSICAL_HEADER_LINE_BYTES - 2);
        raw.extend(std::iter::repeat_n(b'a', initial));
        remaining -= initial;

        while remaining > 0 {
            let contribution = remaining.min(MAX_PHYSICAL_HEADER_LINE_BYTES);
            raw.extend_from_slice(b"\r\n ");
            raw.extend(std::iter::repeat_n(b'a', contribution - 1));
            remaining -= contribution;
        }
        raw.extend_from_slice(b"\r\n\r\nbody");
        raw
    }

    fn header_block_of_size(block_size: usize) -> Vec<u8> {
        let mut remaining = block_size - 2;
        let mut raw = Vec::with_capacity(block_size + 4);
        while remaining >= MAX_PHYSICAL_HEADER_LINE_BYTES + 2 {
            raw.push(b'X');
            raw.extend(std::iter::repeat_n(
                b'a',
                MAX_PHYSICAL_HEADER_LINE_BYTES - 2,
            ));
            raw.extend_from_slice(b":\r\n");
            remaining -= MAX_PHYSICAL_HEADER_LINE_BYTES + 2;
        }
        assert!(remaining >= 4);
        raw.extend_from_slice(b"X:");
        raw.extend(std::iter::repeat_n(b'a', remaining - 4));
        raw.extend_from_slice(b"\r\n\r\nbody");
        raw
    }

    fn multipart_with_leaf_parts(child_parts: usize) -> Vec<u8> {
        let mut raw = b"Content-Type: multipart/mixed; boundary=x\r\n\r\n".to_vec();
        for _ in 0..child_parts {
            raw.extend_from_slice(b"--x\r\nContent-Type: text/plain\r\n\r\nx\r\n");
        }
        raw.extend_from_slice(b"--x--\r\n");
        raw
    }

    fn nested_multipart(depth: usize) -> Vec<u8> {
        let mut message = b"Content-Type: text/plain\r\n\r\nleaf".to_vec();
        for level in 0..depth {
            let boundary = format!("boundary-{level}");
            let mut wrapped = format!(
                "Content-Type: multipart/mixed; boundary={boundary}\r\n\r\n--{boundary}\r\n"
            )
            .into_bytes();
            wrapped.extend_from_slice(&message);
            wrapped.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
            message = wrapped;
        }
        message
    }

    fn nested_rfc822(depth: usize) -> Vec<u8> {
        let mut message = b"Content-Type: text/plain\r\n\r\nleaf".to_vec();
        for _ in 0..depth {
            let mut wrapped = b"Content-Type: message/rfc822\r\n\r\n".to_vec();
            wrapped.extend_from_slice(&message);
            message = wrapped;
        }
        message
    }
}
