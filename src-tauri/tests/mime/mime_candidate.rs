use mail_parser::{MessageParser, MimeHeaders, PartType};

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
    }
}
