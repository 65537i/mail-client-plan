use mail_client_lib::mime_poc::{self, MimeError};
use mail_parser::{MessageParser, MimeHeaders, PartType};

#[path = "async_source.rs"]
mod async_source;

#[test]
fn ac04_charset_diagnostics_distinguish_fallback_and_replacement_presence() {
    for (charset, body, unknown, replacement) in [
        ("utf-8", &b"Synthetic \xff"[..], false, true),
        ("UTF-8", &b"Synthetic \xef\xbf\xbd"[..], false, true),
        ("utf8", &b"Synthetic ASCII"[..], false, false),
        ("x-private-charset", &b"Synthetic ASCII"[..], true, false),
        ("x-private-charset", &b"Synthetic \xff"[..], true, true),
        ("shift_jis", &b"\x93\xfa\x96\x7b\x8c\xea"[..], false, false),
        ("iso-2022-jp", &b"\x1b$BF|K\\8l\x1b(B"[..], false, false),
    ] {
        let mut raw = format!("Content-Type: text/plain; charset={charset}\r\n\r\n").into_bytes();
        raw.extend_from_slice(body);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
        assert_eq!(diagnostics.unrecognized_text_charset, unknown);
        assert_eq!(diagnostics.replacement_character_present, replacement);
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            message.body_text(0),
            mime_poc::parse(&raw).unwrap().body_text(0)
        );
        let debug = format!("{diagnostics:?}");
        assert!(!debug.contains("private-charset"));
        assert!(!debug.contains("Synthetic"));
    }
}

#[test]
fn ac04_charset_diagnostics_cover_html_and_nested_text_attachments() {
    let raw = b"Content-Type: multipart/mixed; boundary=diag\r\n\r\n--diag\r\nContent-Type: text/html; charset=x-private-charset\r\n\r\n<p>Synthetic</p>\r\n--diag\r\nContent-Type: message/rfc822\r\nContent-Disposition: attachment\r\n\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Disposition: attachment\r\n\r\nSynthetic \xff\r\n--diag--\r\n";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    assert!(diagnostics.unrecognized_text_charset);
    assert!(diagnostics.replacement_character_present);
    assert_eq!(message.body_html(0).as_deref(), Some("<p>Synthetic</p>"));
    assert_eq!(message.raw_message.as_ref(), raw);
}

#[test]
fn ac04_charset_diagnostics_ignore_binary_and_do_not_infer_missing_charset() {
    for raw in [
        &b"Content-Type: application/octet-stream; charset=x-private-charset\r\nContent-Disposition: attachment\r\n\r\n\xef\xbf\xbd"[..],
        b"Content-Type: text/plain\r\n\r\nSynthetic ASCII",
    ] {
        let (_, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
        assert_eq!(diagnostics, mime_poc::MimeDiagnostics::default());
    }
    let raw = b"Content-Type: text/plain\r\n\r\nSynthetic \xff";
    let (_, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    assert!(!diagnostics.unrecognized_text_charset);
    assert!(diagnostics.replacement_character_present);
}

#[test]
fn ac04_charset_diagnostics_do_not_turn_invalid_mime_into_success() {
    for raw in [
        &b""[..],
        b"Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n!!!!",
    ] {
        assert_eq!(
            mime_poc::parse_with_diagnostics(raw).unwrap_err(),
            mime_poc::parse(raw).unwrap_err()
        );
    }
}

#[test]
fn ac04_decodes_rfc2047_subject_and_japanese_charsets() {
    for (charset, body) in [
        ("utf-8", &b"\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e"[..]),
        ("shift_jis", &b"\x93\xfa\x96\x7b\x8c\xea"[..]),
        ("iso-2022-jp", &b"\x1b$BF|K\\8l\x1b(B"[..]),
    ] {
        let mut raw = format!(
            "Subject: =?UTF-8?B?5pel5pys6Kqe?=\r\nContent-Type: text/plain; charset={charset}\r\n\r\n"
        ).into_bytes();
        raw.extend_from_slice(body);
        let message = MessageParser::default()
            .parse(&raw)
            .expect("synthetic Japanese message");
        assert_eq!(message.subject(), Some("\u{65e5}\u{672c}\u{8a9e}"));
        assert_eq!(
            message.body_text(0).as_deref(),
            Some("\u{65e5}\u{672c}\u{8a9e}")
        );
    }
}

#[test]
fn ac04_keeps_alternative_bodies_separate_and_html_untrusted() {
    let raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/alternative; boundary=alt\r\n\r\n--alt\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nSynthetic plain text\r\n--alt\r\nContent-Type: text/html; charset=utf-8\r\n\r\n<script>untrusted()</script><p>Synthetic HTML</p>\r\n--alt--\r\n";
    let message = MessageParser::default()
        .parse(raw)
        .expect("multipart alternative");
    assert_eq!(
        message.body_text(0).as_deref(),
        Some("Synthetic plain text")
    );
    assert_eq!(
        message.body_html(0).as_deref(),
        Some("<script>untrusted()</script><p>Synthetic HTML</p>")
    );
    assert_eq!(message.attachment_count(), 0);
}

#[test]
fn ac04_decodes_rfc2231_attachment_name_without_treating_it_as_a_path() {
    let raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=mix\r\n\r\n--mix\r\nContent-Type: text/plain\r\n\r\nSynthetic body\r\n--mix\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*=utf-8''..%2F%E6%97%A5%E6%9C%AC%E8%AA%9E.bin\r\nContent-Transfer-Encoding: base64\r\n\r\nAAECAw==\r\n--mix--\r\n";
    let message = MessageParser::default()
        .parse(raw)
        .expect("synthetic attachment");
    assert_eq!(message.attachment_count(), 1);
    let attachment = message.attachment(0).expect("decoded attachment");
    assert_eq!(
        attachment.attachment_name(),
        Some("../\u{65e5}\u{672c}\u{8a9e}.bin")
    );
    assert_eq!(attachment.contents(), [0, 1, 2, 3]);
}

#[test]
fn ac04_preserves_duplicate_cids_for_explicit_ambiguity_handling() {
    let raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=cid\r\n\r\n--cid\r\nContent-Type: text/plain\r\n\r\nSynthetic\r\n--cid\r\nContent-Type: image/png\r\nContent-Disposition: attachment\r\nContent-ID: <duplicate>\r\n\r\none\r\n--cid\r\nContent-Type: image/png\r\nContent-Disposition: attachment\r\nContent-ID: <duplicate>\r\n\r\ntwo\r\n--cid--\r\n";
    let message = MessageParser::default()
        .parse(raw)
        .expect("duplicate CID fixture");
    assert_eq!(message.attachment_count(), 2);
    assert!(
        message
            .attachments()
            .all(|part| part.content_id() == Some("duplicate"))
    );
    assert_ne!(
        message.attachment(0).unwrap().contents(),
        message.attachment(1).unwrap().contents()
    );
}

#[test]
fn ac04_flags_invalid_base64_instead_of_treating_it_as_valid_decoded_content() {
    let raw = b"Content-Type: application/octet-stream\r\nContent-Disposition: attachment\r\nContent-Transfer-Encoding: base64\r\n\r\n!!!!";
    let message = MessageParser::default()
        .parse(raw)
        .expect("recover malformed encoding");
    assert!(message.parts.iter().any(|part| part.is_encoding_problem));
}

#[test]
fn ac04_truncated_multipart_preserves_raw_source_but_does_not_promise_a_body() {
    let raw = b"Content-Type: multipart/mixed; boundary=cut\r\n\r\n--cut\r\nContent-Type: text/plain\r\n\r\nSynthetic truncated body";
    let message = MessageParser::default()
        .parse(raw)
        .expect("recover truncated multipart");
    assert!(message.body_text(0).is_none());
    assert!(message.body_html(0).is_none());
    assert_eq!(message.raw_message.as_ref(), raw);
}

#[test]
fn ac04_invalid_utf8_is_replaced_without_a_transfer_encoding_error() {
    let raw = b"Content-Type: text/plain; charset=utf-8\r\n\r\nSynthetic \xff text";
    let message = MessageParser::default()
        .parse(raw)
        .expect("invalid UTF-8 fixture");
    assert_eq!(
        message.body_text(0).as_deref(),
        Some("Synthetic \u{fffd} text")
    );
    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    assert_eq!(message.raw_message.as_ref(), raw);
}

#[test]
fn ac04_unknown_charset_falls_back_without_promising_correct_decoding() {
    let raw = b"Content-Type: text/plain; charset=x-synthetic-unknown\r\n\r\nSynthetic ASCII";
    let message = MessageParser::default()
        .parse(raw)
        .expect("unknown charset fixture");
    assert_eq!(message.body_text(0).as_deref(), Some("Synthetic ASCII"));
    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    assert_eq!(message.raw_message.as_ref(), raw);
}

fn nested_multipart(depth: usize) -> String {
    let mut raw = String::new();
    for level in 0..depth {
        raw.push_str(&format!(
            "Content-Type: multipart/mixed; boundary=level-{level}\r\n\r\n--level-{level}\r\n"
        ));
    }
    raw.push_str("Content-Type: text/plain\r\n\r\nSynthetic nested body");
    for level in (0..depth).rev() {
        raw.push_str(&format!("\r\n--level-{level}--\r\n"));
    }
    raw
}

#[test]
fn mime_candidate_does_not_enforce_the_product_multipart_depth_limit() {
    for depth in [29, 30, 31, 128] {
        let raw = nested_multipart(depth);
        let message = MessageParser::default()
            .parse(&raw)
            .expect("nested MIME fixture");
        assert_eq!(message.parts.len(), depth + 1);
        let mut part = &message.parts[0];
        let mut observed_depth = 0;
        while let PartType::Multipart(children) = &part.body {
            assert_eq!(children.len(), 1);
            part = &message.parts[children[0] as usize];
            observed_depth += 1;
        }
        assert_eq!(observed_depth, depth);
        assert_eq!(part.contents(), b"Synthetic nested body");
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    }
}

#[test]
fn mime_candidate_does_not_enforce_the_product_attachment_size_limit() {
    const LIMIT: usize = 25 * 1024 * 1024;
    for size in [LIMIT - 1, LIMIT, LIMIT + 1] {
        let mut raw = b"Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=synthetic.bin\r\nContent-Transfer-Encoding: binary\r\n\r\n".to_vec();
        raw.resize(raw.len() + size, b'x');
        let message = MessageParser::default()
            .parse(&raw)
            .expect("large attachment fixture");
        assert_eq!(message.attachment_count(), 1);
        let attachment = message.attachment(0).expect("binary attachment");
        assert_eq!(attachment.contents().len(), size);
        assert!(attachment.contents().iter().all(|byte| *byte == b'x'));
        assert!(!attachment.is_encoding_problem);
        match mime_poc::parse(&raw) {
            Ok(_) => assert!(size <= LIMIT),
            Err(error) => {
                assert_eq!(size, LIMIT + 1);
                assert_eq!(error, MimeError::AttachmentTooLarge);
            }
        }
    }
}

#[test]
fn ac04_mime_adapter_checks_decoded_budget_after_charset_expansion() {
    for decoded_size in [
        mime_poc::MAX_DECODED_BYTES - 1,
        mime_poc::MAX_DECODED_BYTES,
        mime_poc::MAX_DECODED_BYTES + 1,
    ] {
        let mut raw = b"Content-Type: text/plain; charset=windows-1252\r\n\r\n".to_vec();
        let header_size = raw.len();
        // Windows-1252 0x80 becomes the three-byte UTF-8 euro sign.
        raw.resize(header_size + decoded_size / 3, 0x80);
        raw.resize(raw.len() + decoded_size % 3, b'x');
        assert!(raw.len() < mime_poc::MAX_RAW_BYTES);
        {
            let message = MessageParser::default()
                .parse(&raw)
                .expect("synthetic charset expansion");
            assert_eq!(message.parts.len(), 1);
            let body = message.body_text(0).expect("decoded plain text");
            assert_eq!(body.len(), decoded_size);
            assert!(
                body.as_bytes()[..decoded_size - decoded_size % 3]
                    .as_chunks::<3>()
                    .0
                    .iter()
                    .all(|bytes| bytes == b"\xe2\x82\xac")
            );
            assert!(
                body.as_bytes()[decoded_size - decoded_size % 3..]
                    .iter()
                    .all(|byte| *byte == b'x')
            );
            assert!(!message.parts[0].is_encoding_problem);
        }
        match mime_poc::parse(&raw) {
            Ok(message) => {
                assert!(decoded_size <= mime_poc::MAX_DECODED_BYTES);
                assert_eq!(message.parts[0].contents().len(), decoded_size);
                assert_eq!(message.raw_message.as_ref(), raw);
            }
            Err(error) => {
                assert_eq!(decoded_size, mime_poc::MAX_DECODED_BYTES + 1);
                assert_eq!(error, MimeError::DecodedTooLarge);
            }
        }
        assert_eq!(raw.len(), header_size + decoded_size / 3 + decoded_size % 3);
        assert!(
            raw[header_size..header_size + decoded_size / 3]
                .iter()
                .all(|byte| *byte == 0x80)
        );
    }
}

#[test]
fn ac04_base64_attachments_and_inline_images_enforce_decoded_size_limit() {
    for inline in [false, true] {
        for size in [
            mime_poc::MAX_ATTACHMENT_BYTES - 1,
            mime_poc::MAX_ATTACHMENT_BYTES,
            mime_poc::MAX_ATTACHMENT_BYTES + 1,
        ] {
            let (subtype, body_type, disposition) = if inline {
                ("related", "text/html", "inline")
            } else {
                ("mixed", "text/plain", "attachment")
            };
            let mut raw = format!(
                "MIME-Version: 1.0\r\nContent-Type: multipart/{subtype}; boundary=encoded\r\n\r\n--encoded\r\nContent-Type: {body_type}\r\n\r\nSynthetic body\r\n--encoded\r\nContent-Type: image/png\r\nContent-Disposition: {disposition}\r\nContent-ID: <synthetic-image>\r\nContent-Transfer-Encoding: base64\r\n\r\n"
            ).into_bytes();
            let groups = size / 3;
            for group in 0..groups {
                raw.extend_from_slice(b"QUFB");
                if group % 19 == 18 {
                    raw.extend_from_slice(b"\r\n");
                }
            }
            raw.extend_from_slice(match size % 3 {
                1 => b"QQ==",
                2 => b"QUE=",
                _ => b"",
            });
            raw.extend_from_slice(b"\r\n--encoded--\r\n");
            assert!(raw.len() < mime_poc::MAX_RAW_BYTES);
            {
                let message = MessageParser::default()
                    .parse(&raw)
                    .expect("synthetic base64 attachment");
                let part = message
                    .parts
                    .iter()
                    .find(|part| part.content_id() == Some("synthetic-image"))
                    .expect("decoded attachment or inline image");
                assert!(matches!(
                    part.body,
                    PartType::Binary(_) | PartType::InlineBinary(_)
                ));
                assert_eq!(part.contents().len(), size);
                assert!(part.contents().iter().all(|byte| *byte == b'A'));
                assert!(!part.is_encoding_problem);
                assert_eq!(message.raw_message.as_ref(), raw);
            }
            match mime_poc::parse(&raw) {
                Ok(message) => {
                    assert!(size <= mime_poc::MAX_ATTACHMENT_BYTES);
                    let part = message
                        .parts
                        .iter()
                        .find(|part| part.content_id() == Some("synthetic-image"))
                        .unwrap();
                    assert_eq!(part.contents().len(), size);
                    assert!(part.contents().iter().all(|byte| *byte == b'A'));
                    assert_eq!(message.raw_message.as_ref(), raw);
                }
                Err(error) => {
                    assert_eq!(size, mime_poc::MAX_ATTACHMENT_BYTES + 1);
                    assert_eq!(error, MimeError::AttachmentTooLarge);
                }
            }
            assert!(raw.ends_with(b"\r\n--encoded--\r\n"));
        }
    }
}

#[test]
fn mime_candidate_does_not_enforce_the_product_raw_message_size_limit() {
    const LIMIT: usize = 50 * 1024 * 1024;
    const HEADER: &[u8] = b"Content-Type: text/plain; charset=utf-8\r\n\r\n";
    for size in [LIMIT - 1, LIMIT, LIMIT + 1] {
        let mut raw = HEADER.to_vec();
        raw.resize(size, b'x');
        let message = MessageParser::default()
            .parse(&raw)
            .expect("large raw message fixture");
        assert_eq!(message.raw_message.len(), size);
        let body = message.body_text(0).expect("large plain body");
        assert_eq!(body.len(), size - HEADER.len());
        assert!(body.bytes().all(|byte| byte == b'x'));
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        match mime_poc::parse(&raw) {
            Ok(_) => assert!(size <= LIMIT),
            Err(error) => {
                assert_eq!(size, LIMIT + 1);
                assert_eq!(error, MimeError::RawTooLarge);
            }
        }
    }
}

#[test]
fn mime_adapter_rejects_excessive_nesting_and_preserves_source() {
    for depth in [29, 30, 31, 128] {
        let raw = nested_multipart(depth);
        let original = raw.clone();
        match mime_poc::parse(raw.as_bytes()) {
            Ok(_) => assert!(depth <= 30),
            Err(error) => {
                assert!(depth > 30);
                assert_eq!(error, MimeError::NestingTooDeep);
            }
        }
        assert_eq!(raw, original);
    }
}

#[test]
fn mime_adapter_reports_incomplete_or_unparseable_without_raw_data_in_errors() {
    for raw in [
        &b""[..],
        b"Content-Type: multipart/mixed; boundary=cut\r\n\r\n--cut\r\nContent-Type: text/plain\r\n\r\nSynthetic truncated body",
        b"Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n!!!!",
    ] {
        let original = raw.to_vec();
        let error = mime_poc::parse(raw).expect_err("invalid MIME must fail explicitly");
        assert!(matches!(error, MimeError::Incomplete | MimeError::Unparseable));
        assert!(!error.to_string().contains("Synthetic"));
        assert_eq!(raw, original);
    }
}
#[test]
fn mime_adapter_checks_raw_limit_before_attempting_to_parse() {
    let raw = vec![0; mime_poc::MAX_RAW_BYTES + 1];
    assert_eq!(mime_poc::parse(&raw).unwrap_err(), MimeError::RawTooLarge);
    assert!(raw.iter().all(|byte| *byte == 0));
}

#[test]
fn mime_adapter_does_not_mark_html_as_sanitized() {
    let raw = b"Content-Type: text/html\r\n\r\n<script>untrusted()</script>";
    let message = mime_poc::parse(raw).expect("HTML is data, not sanitized by the size adapter");
    assert_eq!(
        message.body_html(0).as_deref(),
        Some("<script>untrusted()</script>")
    );
}

#[test]
fn mime_adapter_applies_depth_checks_inside_attached_messages() {
    for depth in [29, 30] {
        let raw = format!(
            "Content-Type: message/rfc822\r\nContent-Disposition: attachment\r\n\r\n{}",
            nested_multipart(depth)
        );
        match mime_poc::parse(raw.as_bytes()) {
            Ok(_) => assert_eq!(depth, 29),
            Err(error) => {
                assert_eq!(depth, 30);
                assert_eq!(error, MimeError::NestingTooDeep);
            }
        }
    }
}
#[test]
fn ac04_encoded_attached_messages_report_the_parser_recursion_limit() {
    for depth in [1, 2, 3, 4, 5] {
        let mut raw = "Subject: Synthetic inner message\r\nContent-Type: text/plain\r\n\r\nSynthetic inner body".to_owned();
        let mut layers = vec![raw.clone()];
        for _ in 0..depth {
            raw = format!(
                "Content-Type: message/rfc822\r\nContent-Disposition: attachment\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n{}",
                raw.replace('=', "=3D")
            );
            layers.push(raw.clone());
        }
        let original = raw.clone();
        let message = MessageParser::default()
            .parse(&raw)
            .expect("synthetic encoded attached message");
        let mut part = &message.parts[0];
        let mut parsed_depth = 0;
        while let PartType::Message(nested) = &part.body {
            assert!(!part.is_encoding_problem);
            assert_eq!(nested.parts.len(), 1);
            part = &nested.parts[0];
            parsed_depth += 1;
        }
        assert_eq!(parsed_depth, depth.min(3));
        if depth <= 3 {
            assert_eq!(part.contents(), b"Synthetic inner body");
            assert!(!part.is_encoding_problem);
            assert!(mime_poc::parse(raw.as_bytes()).is_ok());
        } else {
            assert!(matches!(part.body, PartType::Binary(_)));
            assert!(part.is_encoding_problem);
            assert_eq!(part.contents(), layers[depth - 4].as_bytes());
            let error = mime_poc::parse(raw.as_bytes())
                .expect_err("unparsed attached message must not count as complete");
            assert_eq!(error, MimeError::Incomplete);
            for diagnostic in [error.to_string(), format!("{error:?}")] {
                assert!(!diagnostic.contains("Synthetic"));
            }
        }
        assert_eq!(message.raw_message.as_ref(), raw.as_bytes());
        assert_eq!(raw, original);
    }
}
