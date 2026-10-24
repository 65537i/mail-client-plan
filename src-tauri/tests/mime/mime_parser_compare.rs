use mail_parser::{MessageParser, MimeHeaders, PartType};
use mailparse::MailHeaderMap;
use rmimeparser::{
    ContentDisposition, MessageHandler, MessageParser as RmimeMessageParser, MimeHandler,
    MimeParseError, MimeParser, ParseResult,
};

#[derive(Default)]
struct RmimeParserProbe {
    decoded_body: Vec<u8>,
    max_body_chunk: usize,
    child_entities: usize,
    decoded_limit: Option<usize>,
    entity_limit: Option<usize>,
    nesting_limit: Option<usize>,
    entity_multipart: Vec<bool>,
    max_multipart_depth: usize,
    attachment_filenames: Vec<String>,
}

impl MimeHandler for RmimeParserProbe {
    fn start_entity(&mut self, boundary: Option<&str>) -> ParseResult<()> {
        if boundary.is_some() {
            self.child_entities += 1;
            if self
                .entity_limit
                .is_some_and(|limit| self.child_entities > limit)
            {
                return Err(MimeParseError::new("part limit exceeded"));
            }
        }
        self.entity_multipart.push(false);
        Ok(())
    }

    fn content_type(&mut self, content_type: &rmimeparser::ContentType) -> ParseResult<()> {
        if content_type.is_primary_type("multipart")
            && let Some(current) = self.entity_multipart.last_mut()
            && !*current
        {
            *current = true;
            let depth = self
                .entity_multipart
                .iter()
                .filter(|is_multipart| **is_multipart)
                .count();
            self.max_multipart_depth = self.max_multipart_depth.max(depth);
            if self.nesting_limit.is_some_and(|limit| depth > limit) {
                return Err(MimeParseError::new("nesting limit exceeded"));
            }
        }
        Ok(())
    }

    fn content_disposition(&mut self, disposition: &ContentDisposition) -> ParseResult<()> {
        if disposition.is_disposition_type("attachment")
            && let Some(filename) = disposition.parameter("filename")
        {
            self.attachment_filenames.push(filename.to_owned());
        }
        Ok(())
    }

    fn body_content(&mut self, content: &[u8]) -> ParseResult<()> {
        self.max_body_chunk = self.max_body_chunk.max(content.len());
        if self
            .decoded_limit
            .is_some_and(|limit| self.decoded_body.len().saturating_add(content.len()) > limit)
        {
            return Err(MimeParseError::new("decoded body limit exceeded"));
        }
        self.decoded_body.extend_from_slice(content);
        Ok(())
    }

    fn end_entity(&mut self, _boundary: Option<&str>) -> ParseResult<()> {
        assert!(self.entity_multipart.pop().is_some());
        Ok(())
    }
}

impl MessageHandler for RmimeParserProbe {}

fn run_rmimeparser(raw: &[u8], probe: &mut RmimeParserProbe) -> ParseResult<()> {
    let mut parser = MimeParser::new(probe);
    parser
        .set_max_buffer_size(16)
        .expect("positive chunk size is valid");
    parser
        .set_max_header_value_size(16 * 1024)
        .expect("positive header limit is valid");
    let mut input = raw;
    parser.finish(&mut input)?;
    assert!(input.is_empty());
    drop(parser);
    assert!(probe.entity_multipart.is_empty());
    Ok(())
}

fn rmimeparser_body(raw: &[u8]) -> RmimeParserProbe {
    let mut probe = RmimeParserProbe::default();
    run_rmimeparser(raw, &mut probe).expect("rmimeparser should parse the selected corpus input");
    probe
}

#[derive(Default)]
struct RmimeMessageProbe {
    body: Vec<u8>,
    max_body_chunk: usize,
    subjects: Vec<String>,
    unstructured_headers: Vec<(String, String)>,
}

impl MimeHandler for RmimeMessageProbe {
    fn body_content(&mut self, content: &[u8]) -> ParseResult<()> {
        self.max_body_chunk = self.max_body_chunk.max(content.len());
        self.body.extend_from_slice(content);
        Ok(())
    }
}

impl MessageHandler for RmimeMessageProbe {
    fn header(&mut self, name: &str, value: &str) -> ParseResult<()> {
        self.unstructured_headers
            .push((name.to_owned(), value.to_owned()));
        if name.eq_ignore_ascii_case("subject") {
            self.subjects.push(value.to_owned());
        }
        Ok(())
    }
}

fn rmimeparser_message(raw: &[u8], probe: &mut RmimeMessageProbe) -> ParseResult<()> {
    let mut parser = RmimeMessageParser::new(probe);
    let mut input = raw;
    parser.finish(&mut input)?;
    assert!(input.is_empty());
    Ok(())
}

fn rmimeparser_message_chunked(
    raw: &[u8],
    probe: &mut RmimeMessageProbe,
    chunk_size: usize,
) -> ParseResult<()> {
    assert!(chunk_size > 0);
    let mut parser = RmimeMessageParser::new(probe);
    let mut pending = Vec::new();
    for chunk in raw.chunks(chunk_size) {
        pending.extend_from_slice(chunk);
        let consumed = {
            let mut input = pending.as_slice();
            parser.receive(&mut input)?;
            pending.len() - input.len()
        };
        pending.drain(..consumed);
    }
    let mut input = pending.as_slice();
    parser.finish(&mut input)?;
    assert!(input.is_empty());
    Ok(())
}

fn message_with_folded_header_value(value_size: usize) -> Vec<u8> {
    let mut raw = b"X-Long:".to_vec();
    let first_line_size = value_size.min(900);
    raw.extend(std::iter::repeat_n(b'x', first_line_size));
    raw.extend_from_slice(b"\r\n");

    let mut remaining = value_size - first_line_size;
    while remaining > 0 {
        let line_value_size = remaining.min(997);
        raw.push(b' ');
        raw.extend(std::iter::repeat_n(b'x', line_value_size - 1));
        raw.extend_from_slice(b"\r\n");
        remaining -= line_value_size;
    }

    raw.extend_from_slice(b"Subject: after long header\r\n\r\nbody");
    raw
}

fn message_with_header_line(line_size: usize) -> Vec<u8> {
    let mut raw = b"X-Long:".to_vec();
    raw.extend(std::iter::repeat_n(b'x', line_size - b"X-Long:".len()));
    raw.extend_from_slice(b"\r\nSubject: after long line\r\n\r\nbody");
    raw
}

struct CorpusCase {
    name: &'static str,
    source: Vec<u8>,
    expected_text_parts: &'static [&'static str],
    mail_parser_text_parts: &'static [&'static str],
}

fn multipart_qp(source_line_ending: &[u8], body: &[u8], continuation: bool) -> Vec<u8> {
    let mut raw = b"MIME-Version: 1.0".to_vec();
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=compare");
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(b"--compare");
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(body);
    if continuation {
        raw.extend_from_slice(b"continued");
        raw.extend_from_slice(source_line_ending);
    }
    raw.extend_from_slice(b"--compare");
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(b"second part");
    raw.extend_from_slice(source_line_ending);
    raw.extend_from_slice(b"--compare--");
    raw.extend_from_slice(source_line_ending);
    raw
}

fn corpus() -> Vec<CorpusCase> {
    let mut cases = vec![
        CorpusCase {
            name: "quoted-printable soft break at CRLF multipart boundary",
            source: multipart_qp(b"\r\n", b"before=\r\n", false),
            expected_text_parts: &["before", "second part"],
            mail_parser_text_parts: &["befo", "second part"],
        },
        CorpusCase {
            name: "quoted-printable soft break at LF multipart boundary",
            source: multipart_qp(b"\n", b"before=\n", false),
            expected_text_parts: &["before", "second part"],
            mail_parser_text_parts: &["befor", "second part"],
        },
        CorpusCase {
            name: "quoted-printable soft break followed by body data",
            source: multipart_qp(b"\r\n", b"before=\r\n", true),
            expected_text_parts: &["beforecontinued", "second part"],
            mail_parser_text_parts: &["beforecontinued", "second part"],
        },
        CorpusCase {
            name: "quoted-printable UTF-8 token split at soft break",
            source: multipart_qp(b"\r\n", b"=C3=\r\n=A9tail\r\n", false),
            expected_text_parts: &["étail", "second part"],
            mail_parser_text_parts: &["étail", "second part"],
        },
    ];

    cases.push(CorpusCase {
        name: "multipart alternative text and HTML",
        source: b"Content-Type: multipart/alternative; boundary=alternative\r\n\r\n--alternative\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic plain\r\n--alternative\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<p>Synthetic HTML</p>\r\n--alternative--\r\n".to_vec(),
        expected_text_parts: &["Synthetic plain", "<p>Synthetic HTML</p>"],
        mail_parser_text_parts: &["Synthetic plain", "<p>Synthetic HTML</p>"],
    });

    let mut shift_jis = b"Content-Type: text/plain; charset=shift_jis\r\n\r\n".to_vec();
    shift_jis.extend_from_slice(b"\x93\xfa\x96\x7b\x8c\xea");
    cases.push(CorpusCase {
        name: "Japanese Shift_JIS text",
        source: shift_jis,
        expected_text_parts: &["日本語"],
        mail_parser_text_parts: &["日本語"],
    });

    cases
}

fn nested_multipart(depth: usize) -> Vec<u8> {
    let mut nested =
        b"Content-Type: text/plain; charset=utf-8\r\n\r\nSynthetic nested body".to_vec();
    for level in (0..depth).rev() {
        let boundary = format!("depth-{level:04}");
        let mut raw =
            format!("Content-Type: multipart/mixed; boundary={boundary}\r\n\r\n--{boundary}\r\n")
                .into_bytes();
        raw.extend_from_slice(&nested);
        raw.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        nested = raw;
    }
    nested
}

fn nested_attached_messages(depth: usize) -> Vec<u8> {
    let mut nested =
        b"Content-Type: text/plain; charset=utf-8\r\n\r\nSynthetic attached body".to_vec();
    for _ in 0..depth {
        let mut raw =
            b"Content-Type: message/rfc822\r\nContent-Disposition: attachment\r\n\r\n".to_vec();
        raw.extend_from_slice(&nested);
        nested = raw;
    }
    nested
}

fn multipart_with_text_parts(count: usize) -> Vec<u8> {
    let mut raw = b"Content-Type: multipart/mixed; boundary=many\r\n\r\n".to_vec();
    for _ in 0..count {
        raw.extend_from_slice(b"--many\r\nContent-Type: text/plain\r\n\r\nx\r\n");
    }
    raw.extend_from_slice(b"--many--\r\n");
    raw
}

fn mail_parser_text_parts(raw: &[u8]) -> Vec<String> {
    let message = MessageParser::default()
        .parse(raw)
        .expect("legacy candidate should parse the selected corpus fixture");
    message
        .parts
        .iter()
        .filter_map(|part| match &part.body {
            PartType::Text(text) | PartType::Html(text) => Some(text.to_string()),
            _ => None,
        })
        .collect()
}

fn mailparse_text_parts(parsed: &mailparse::ParsedMail<'_>, output: &mut Vec<String>) {
    if parsed.subparts.is_empty() {
        if parsed.ctype.mimetype.starts_with("text/") {
            output.push(
                parsed
                    .get_body()
                    .expect("mailparse should decode text in the selected corpus")
                    .trim_end_matches(['\r', '\n'])
                    .to_owned(),
            );
        }
        return;
    }
    for part in &parsed.subparts {
        mailparse_text_parts(part, output);
    }
}

#[test]
fn mime_parser_candidates_receive_the_same_regression_corpus() {
    let cases = corpus();
    assert_eq!(cases.len(), 6);

    for case in cases {
        let mailparse = mailparse::parse_mail(&case.source)
            .unwrap_or_else(|error| panic!("mailparse failed {}: {error:?}", case.name));
        let mut candidate_text = Vec::new();
        mailparse_text_parts(&mailparse, &mut candidate_text);
        let expected: Vec<_> = case
            .expected_text_parts
            .iter()
            .map(|s| (*s).to_owned())
            .collect();
        let legacy_expected: Vec<_> = case
            .mail_parser_text_parts
            .iter()
            .map(|s| (*s).to_owned())
            .collect();

        assert_eq!(candidate_text, expected, "mailparse: {}", case.name);
        assert_eq!(
            mail_parser_text_parts(&case.source),
            legacy_expected,
            "mail-parser baseline: {}",
            case.name
        );
    }
}

#[test]
fn rmimeparser_streaming_candidate_receives_the_same_regression_corpus() {
    for case in corpus() {
        let candidate = rmimeparser_body(&case.source);
        let expected = if case.name == "Japanese Shift_JIS text" {
            b"\x93\xfa\x96\x7b\x8c\xea".to_vec()
        } else {
            case.expected_text_parts.join("").into_bytes()
        };
        assert_eq!(candidate.decoded_body, expected, "{}", case.name);
        assert!(
            candidate.max_body_chunk <= 16,
            "body chunk exceeded configured buffer for {}",
            case.name
        );
    }
}

#[test]
fn rmimeparser_message_parser_composes_rfc5322_headers_with_the_mime_corpus() {
    for case in corpus() {
        let mut message = b"From: sender@example.test\r\nSubject: RFC 5322 probe\r\n".to_vec();
        message.extend_from_slice(&case.source);

        let mut probe = RmimeMessageProbe::default();
        rmimeparser_message(&message, &mut probe)
            .unwrap_or_else(|error| panic!("MessageParser failed {}: {error:?}", case.name));

        let expected = if case.name == "Japanese Shift_JIS text" {
            b"\x93\xfa\x96\x7b\x8c\xea".to_vec()
        } else {
            case.expected_text_parts.join("").into_bytes()
        };
        assert_eq!(probe.body, expected, "{}", case.name);
        assert_eq!(probe.subjects, ["RFC 5322 probe"], "{}", case.name);
        assert!(
            probe.max_body_chunk <= 4096,
            "MessageParser default body chunk limit exceeded for {}",
            case.name
        );
    }
}

#[test]
fn rmimeparser_message_parser_does_not_forward_unrecognized_headers() {
    let raw = b"Subject: visible\r\nX-Client-Extension: visible\r\nList-Unsubscribe: <mailto:leave@example.test>\r\n\r\nbody";
    let mut probe = RmimeMessageProbe::default();
    rmimeparser_message(raw, &mut probe).expect("parse RFC 5322 header capability probe");

    assert_eq!(
        probe.unstructured_headers,
        [
            ("Subject".to_owned(), "visible".to_owned()),
            ("X-Client-Extension".to_owned(), "visible".to_owned()),
        ]
    );
    assert!(
        !probe
            .unstructured_headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("list-unsubscribe"))
    );
    assert_eq!(probe.body, b"body");
}

#[test]
fn rmimeparser_message_parser_preserves_results_across_input_chunk_boundaries() {
    for case in corpus() {
        let mut message = b"From: sender@example.test\r\nSubject: RFC 5322 probe\r\n".to_vec();
        message.extend_from_slice(&case.source);
        let expected_body = if case.name == "Japanese Shift_JIS text" {
            b"\x93\xfa\x96\x7b\x8c\xea".to_vec()
        } else {
            case.expected_text_parts.join("").into_bytes()
        };

        for chunk_size in [1, 2, 3, 7, 31, 997] {
            let mut probe = RmimeMessageProbe::default();
            rmimeparser_message_chunked(&message, &mut probe, chunk_size).unwrap_or_else(|error| {
                panic!(
                    "MessageParser failed {} with {chunk_size}-byte chunks: {error:?}",
                    case.name
                )
            });
            assert_eq!(
                probe.body, expected_body,
                "{} with {chunk_size}-byte chunks",
                case.name
            );
            assert_eq!(
                probe.subjects,
                ["RFC 5322 probe"],
                "{} with {chunk_size}-byte chunks",
                case.name
            );
        }
    }
}

#[test]
fn rmimeparser_message_parser_enforces_default_header_value_limit_across_chunks() {
    for chunk_size in [1, 997] {
        let at_limit = message_with_folded_header_value(32 * 1024);
        let mut probe = RmimeMessageProbe::default();
        rmimeparser_message_chunked(&at_limit, &mut probe, chunk_size).unwrap_or_else(|error| {
            panic!("32 KiB header rejected with {chunk_size}-byte chunks: {error}")
        });
        assert_eq!(probe.subjects, ["after long header"]);
        assert_eq!(probe.body, b"body");

        let over_limit = message_with_folded_header_value(32 * 1024 + 1);
        let mut probe = RmimeMessageProbe::default();
        let error = rmimeparser_message_chunked(&over_limit, &mut probe, chunk_size).unwrap_err();
        assert!(
            error.message().contains("32768"),
            "unexpected header limit error for {chunk_size}-byte chunks: {error}"
        );
        assert!(probe.subjects.is_empty());
        assert!(probe.body.is_empty());
    }
}

#[test]
fn rmimeparser_message_parser_enforces_header_line_limit_across_chunks() {
    for chunk_size in [1, 997] {
        let at_limit = message_with_header_line(998);
        let mut probe = RmimeMessageProbe::default();
        rmimeparser_message_chunked(&at_limit, &mut probe, chunk_size).unwrap_or_else(|error| {
            panic!("998-character header rejected with {chunk_size}-byte chunks: {error}")
        });
        assert_eq!(probe.subjects, ["after long line"]);
        assert_eq!(probe.body, b"body");

        let over_limit = message_with_header_line(999);
        let mut probe = RmimeMessageProbe::default();
        let error = rmimeparser_message_chunked(&over_limit, &mut probe, chunk_size).unwrap_err();
        assert!(
            error.message().contains("maximum of 998 characters"),
            "unexpected line length error with {chunk_size}-byte chunks: {error}"
        );
        assert!(probe.subjects.is_empty());
        assert!(probe.body.is_empty());
    }
}

#[test]
fn rmimeparser_message_parser_forwards_resource_budget_failures() {
    let mut raw = b"Subject: budget probe\r\nContent-Type: text/plain\r\n\r\n".to_vec();
    raw.extend(std::iter::repeat_n(b'x', 8192));
    let mut probe = RmimeParserProbe {
        decoded_limit: Some(100),
        ..RmimeParserProbe::default()
    };
    let error = {
        let mut parser = RmimeMessageParser::new(&mut probe);
        let mut input = &raw[..];
        parser.finish(&mut input).unwrap_err()
    };
    assert_eq!(error.message(), "decoded body limit exceeded");
    assert!(probe.decoded_body.len() <= 100);
    assert!(probe.max_body_chunk <= 4096);

    let raw = multipart_with_text_parts(64);
    let mut probe = RmimeParserProbe {
        entity_limit: Some(32),
        ..RmimeParserProbe::default()
    };
    let error = {
        let mut parser = RmimeMessageParser::new(&mut probe);
        let mut input = &raw[..];
        parser.finish(&mut input).unwrap_err()
    };
    assert_eq!(error.message(), "part limit exceeded");
    assert_eq!(probe.child_entities, 33);

    let raw = nested_multipart(31);
    let mut probe = RmimeParserProbe {
        nesting_limit: Some(30),
        ..RmimeParserProbe::default()
    };
    let error = {
        let mut parser = RmimeMessageParser::new(&mut probe);
        let mut input = &raw[..];
        parser.finish(&mut input).unwrap_err()
    };
    assert_eq!(error.message(), "nesting limit exceeded");
    assert_eq!(probe.max_multipart_depth, 31);
}

#[test]
fn rmimeparser_callbacks_enforce_decoded_part_and_nesting_budgets() {
    let mut raw = b"Content-Type: text/plain\r\n\r\n".to_vec();
    raw.extend(std::iter::repeat_n(b'x', 256));
    let mut decoded_probe = RmimeParserProbe {
        decoded_limit: Some(100),
        ..RmimeParserProbe::default()
    };
    let error = run_rmimeparser(&raw, &mut decoded_probe).unwrap_err();
    assert_eq!(error.message(), "decoded body limit exceeded");
    assert!(decoded_probe.decoded_body.len() <= 100);
    assert!(decoded_probe.max_body_chunk <= 16);

    let raw = multipart_with_text_parts(20_000);
    let mut part_probe = RmimeParserProbe {
        entity_limit: Some(32),
        ..RmimeParserProbe::default()
    };
    let error = run_rmimeparser(&raw, &mut part_probe).unwrap_err();
    assert_eq!(error.message(), "part limit exceeded");
    assert_eq!(part_probe.child_entities, 33);

    let raw = nested_multipart(31);
    let mut depth_probe = RmimeParserProbe {
        nesting_limit: Some(30),
        ..RmimeParserProbe::default()
    };
    let error = run_rmimeparser(&raw, &mut depth_probe).unwrap_err();
    assert_eq!(error.message(), "nesting limit exceeded");
    assert_eq!(depth_probe.max_multipart_depth, 31);
}

#[test]
fn rmimeparser_does_not_report_transfer_decode_losses() {
    let invalid_base64 =
        b"Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n!!!!";
    let parsed = rmimeparser_body(invalid_base64);
    assert!(parsed.decoded_body.is_empty());
    let mut message_probe = RmimeMessageProbe::default();
    rmimeparser_message(invalid_base64, &mut message_probe)
        .expect("MessageParser accepts malformed base64 without a diagnostic");
    assert!(message_probe.body.is_empty());

    let truncated_qp = b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nSynthetic trailing=";
    let parsed = rmimeparser_body(truncated_qp);
    assert_eq!(parsed.decoded_body, b"Synthetic trailing");
    let mut message_probe = RmimeMessageProbe::default();
    rmimeparser_message(truncated_qp, &mut message_probe)
        .expect("MessageParser accepts truncated quoted-printable without a diagnostic");
    assert_eq!(message_probe.body, b"Synthetic trailing");

    let truncated_multipart = b"Content-Type: multipart/mixed; boundary=cut\r\n\r\n--cut\r\nContent-Type: text/plain\r\n\r\nSynthetic truncated body";
    let mut probe = RmimeParserProbe::default();
    let error = run_rmimeparser(truncated_multipart, &mut probe).unwrap_err();
    assert!(error.message().contains("boundary"), "{error}");
    let mut message_probe = RmimeMessageProbe::default();
    let error = {
        let mut parser = RmimeMessageParser::new(&mut message_probe);
        let mut input = &truncated_multipart[..];
        parser.finish(&mut input).unwrap_err()
    };
    assert!(error.message().contains("boundary"), "{error}");
}

#[test]
fn rmimeparser_streams_attachment_bytes_and_decodes_rfc2231_filename() {
    let raw = b"Content-Type: multipart/mixed; boundary=attachments\r\n\r\n--attachments\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"first.bin\"\r\nContent-Transfer-Encoding: base64\r\n\r\nAQID\r\n--attachments\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*=utf-8''%E6%97%A5%E6%9C%AC%E8%AA%9E.bin\r\nContent-Transfer-Encoding: base64\r\n\r\nBAUG\r\n--attachments--\r\n";
    let candidate = rmimeparser_body(raw);
    assert_eq!(candidate.decoded_body, [1, 2, 3, 4, 5, 6]);
    assert_eq!(candidate.attachment_filenames, ["first.bin", "日本語.bin"]);
}

#[test]
fn malformed_and_truncated_mime_require_caller_validation() {
    let truncated = b"Content-Type: multipart/mixed; boundary=cut\r\n\r\n--cut\r\nContent-Type: text/plain\r\n\r\nSynthetic truncated body";
    let parsed = mailparse::parse_mail(truncated).expect("parse truncated multipart");
    assert_eq!(parsed.raw_bytes, truncated);
    assert_eq!(parsed.subparts.len(), 1);
    assert_eq!(
        parsed.subparts[0]
            .get_body()
            .expect("decode recovered truncated part"),
        "Synthetic truncated body"
    );
    let legacy = MessageParser::default()
        .parse(truncated)
        .expect("legacy parser recovers truncated multipart");
    assert!(legacy.body_text(0).is_none());

    let invalid_base64 = b"Content-Type: application/octet-stream\r\nContent-Disposition: attachment\r\nContent-Transfer-Encoding: base64\r\n\r\n!!!!";
    let parsed = mailparse::parse_mail(invalid_base64).expect("parse malformed base64");
    assert_eq!(parsed.raw_bytes, invalid_base64);
    assert!(parsed.get_body().is_err());
    let legacy = MessageParser::default()
        .parse(invalid_base64)
        .expect("legacy parser recovers malformed base64");
    assert!(legacy.parts.iter().any(|part| part.is_encoding_problem));

    let truncated_qp =
        b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nSynthetic trailing=";
    let parsed = mailparse::parse_mail(truncated_qp).expect("parse truncated quoted-printable");
    assert_eq!(parsed.raw_bytes, truncated_qp);
    assert_eq!(
        parsed
            .get_body()
            .expect("decode truncated quoted-printable"),
        "Synthetic trailing"
    );
    let legacy = MessageParser::default()
        .parse(truncated_qp)
        .expect("legacy parser recovers truncated quoted-printable");
    assert_eq!(legacy.body_text(0).as_deref(), Some("Synthetic trailing"));
}

#[test]
fn attachment_bytes_names_and_duplicate_cids_are_available_from_both_candidates() {
    let raw = b"Content-Type: multipart/mixed; boundary=attachments\r\n\r\n--attachments\r\nContent-Type: image/png\r\nContent-Disposition: attachment; filename=\"first.png\"\r\nContent-ID: <duplicate>\r\nContent-Transfer-Encoding: base64\r\n\r\nAQID\r\n--attachments\r\nContent-Type: image/png\r\nContent-Disposition: attachment; filename=\"second.png\"\r\nContent-ID: <duplicate>\r\nContent-Transfer-Encoding: base64\r\n\r\nBAUG\r\n--attachments--\r\n";

    let candidate = mailparse::parse_mail(raw).expect("parse attachment corpus input");
    let candidate_attachments: Vec<_> = candidate
        .parts()
        .filter(|part| {
            matches!(
                part.get_content_disposition().disposition,
                mailparse::DispositionType::Attachment
            )
        })
        .map(|part| {
            (
                part.get_content_disposition().params["filename"].clone(),
                part.headers.get_first_value("Content-ID").unwrap(),
                part.get_body_raw().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        candidate_attachments,
        [
            (
                "first.png".to_owned(),
                "<duplicate>".to_owned(),
                vec![1, 2, 3]
            ),
            (
                "second.png".to_owned(),
                "<duplicate>".to_owned(),
                vec![4, 5, 6]
            ),
        ]
    );

    let legacy = MessageParser::default()
        .parse(raw)
        .expect("parse attachment corpus with legacy candidate");
    assert_eq!(legacy.attachment_count(), 2);
    let legacy_attachments: Vec<_> = legacy
        .attachments()
        .map(|part| {
            (
                part.attachment_name().unwrap().to_owned(),
                part.content_id().unwrap().to_owned(),
                part.contents().to_vec(),
            )
        })
        .collect();
    assert_eq!(
        legacy_attachments,
        [
            (
                "first.png".to_owned(),
                "duplicate".to_owned(),
                vec![1, 2, 3]
            ),
            (
                "second.png".to_owned(),
                "duplicate".to_owned(),
                vec![4, 5, 6]
            ),
        ]
    );
}

#[test]
fn rfc2231_extended_and_continued_filenames_decode_split_utf8() {
    for (parameters, candidate_expected, legacy_expected) in [
        (
            "filename*=utf-8''..%2F%E6%97%A5%E6%9C%AC%E8%AA%9E.bin",
            "../\u{65e5}\u{672c}\u{8a9e}.bin",
            "../\u{65e5}\u{672c}\u{8a9e}.bin",
        ),
        (
            "filename*0*=utf-8''%E6%97; filename*1*=%A5%E6%9C%AC%E8%AA%9E.bin",
            "\u{65e5}\u{672c}\u{8a9e}.bin",
            "\u{fffd}\u{fffd}\u{672c}\u{8a9e}.bin",
        ),
    ] {
        let raw = format!(
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; {parameters}\r\n\r\nSynthetic attachment"
        );
        let candidate = mailparse::parse_mail(raw.as_bytes()).expect("parse extended filename");
        let candidate_filename = candidate
            .get_content_disposition()
            .params
            .get("filename")
            .cloned();
        assert_eq!(candidate_filename.as_deref(), Some(candidate_expected));
        assert_eq!(candidate.get_body_raw().unwrap(), b"Synthetic attachment");

        let legacy = MessageParser::default()
            .parse(raw.as_bytes())
            .expect("parse extended filename with legacy candidate");
        assert_eq!(legacy.attachment_count(), 1);
        assert_eq!(
            legacy.attachment(0).unwrap().attachment_name(),
            Some(legacy_expected)
        );
    }
}

#[test]
fn mailparse_recursion_limit_is_above_the_product_nesting_limit() {
    for depth in [30, 31, 100] {
        let raw = nested_multipart(depth);
        let parsed = mailparse::parse_mail(&raw)
            .unwrap_or_else(|error| panic!("mailparse rejected nesting {depth}: {error:?}"));
        let mut node = &parsed;
        let mut parsed_depth = 0;
        while node.ctype.mimetype.starts_with("multipart/") {
            assert_eq!(node.subparts.len(), 1);
            node = &node.subparts[0];
            parsed_depth += 1;
        }
        assert_eq!(parsed_depth, depth);
        assert_eq!(
            node.get_body().expect("decode deepest nested body"),
            "Synthetic nested body"
        );
    }
    let too_deep = nested_multipart(101);
    assert!(mailparse::parse_mail(&too_deep).is_err());
}

#[test]
fn message_rfc822_reparsing_requires_an_explicit_caller_depth_budget() {
    for (depth, expected_accept) in [(30, true), (31, false)] {
        let mut raw = nested_attached_messages(depth);
        let mut parsed_depth = 0;
        loop {
            if parsed_depth == 30 && !expected_accept {
                break;
            }
            let parsed = mailparse::parse_mail(&raw).expect("parse bounded attached message");
            if parsed.ctype.mimetype != "message/rfc822" {
                assert_eq!(parsed_depth, depth);
                assert!(expected_accept);
                assert_eq!(
                    parsed.get_body().expect("decode nested leaf"),
                    "Synthetic attached body"
                );
                break;
            }
            raw = parsed
                .get_body_raw()
                .expect("decode attached message before reparsing");
            parsed_depth += 1;
        }
    }
}

#[test]
fn utf8_replacement_expansion_can_exceed_the_product_decoded_budget() {
    let body_bytes = 34 * 1024 * 1024;
    let mut raw = b"Content-Type: text/plain; charset=utf-8\r\n\r\n".to_vec();
    raw.extend(std::iter::repeat_n(0xff, body_bytes));
    assert!(raw.len() <= mail_client_lib::mime_poc::MAX_RAW_BYTES);

    let parsed = mailparse::parse_mail(&raw).expect("parse bounded raw message");
    let decoded = parsed
        .get_body()
        .expect("decode invalid UTF-8 with replacement");
    assert_eq!(decoded.len(), body_bytes * 3);
    assert!(decoded.len() > mail_client_lib::mime_poc::MAX_DECODED_BYTES);
}

#[test]
fn multipart_part_count_is_not_limited_by_the_candidate() {
    let count = 20_000;
    let raw = multipart_with_text_parts(count);
    assert!(raw.len() < 1024 * 1024);

    let parsed = mailparse::parse_mail(&raw).expect("parse bounded multipart source");
    assert_eq!(parsed.raw_bytes.len(), raw.len());
    assert_eq!(parsed.subparts.len(), count);
    assert_eq!(parsed.subparts[0].get_body().unwrap(), "x");
    assert_eq!(parsed.subparts[count - 1].get_body().unwrap(), "x");
}

#[test]
fn message_rfc822_is_a_leaf_in_mailparse_but_nested_in_mail_parser() {
    let nested = b"Content-Type: multipart/mixed; boundary=inner\r\n\r\n--inner\r\nContent-Type: text/plain\r\n\r\nSynthetic attached body\r\n--inner--";
    let mut raw = b"Content-Type: message/rfc822\r\nContent-Disposition: attachment; filename=\"attached.eml\"\r\n\r\n".to_vec();
    raw.extend_from_slice(nested);

    let candidate = mailparse::parse_mail(&raw).expect("parse attached message");
    assert_eq!(candidate.ctype.mimetype, "message/rfc822");
    assert!(candidate.subparts.is_empty());
    assert_eq!(candidate.get_body_raw().unwrap(), nested);
    assert_eq!(
        candidate
            .get_content_disposition()
            .params
            .get("filename")
            .map(String::as_str),
        Some("attached.eml")
    );

    let legacy = MessageParser::default()
        .parse(&raw)
        .expect("parse attached message with legacy candidate");
    let PartType::Message(nested_message) = &legacy.parts[0].body else {
        panic!("legacy candidate should expose a parsed attached message");
    };
    assert_eq!(
        nested_message.body_text(0).as_deref(),
        Some("Synthetic attached body")
    );
}
