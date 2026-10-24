use mail_client_lib::mime_poc::{self, MimeError};
use mail_parser::{MessageParser, MimeHeaders, PartType};

#[path = "async_source.rs"]
mod async_source;

fn cid_message(ids: &[&str]) -> String {
    let mut raw = "Content-Type: multipart/mixed; boundary=cid-scope\r\n\r\n--cid-scope\r\nContent-Type: text/plain\r\n\r\nSynthetic CID body\r\n".to_owned();
    for id in ids {
        raw.push_str(&format!(
            "--cid-scope\r\nContent-Type: image/png\r\nContent-Disposition: attachment\r\nContent-ID: <{id}>\r\n\r\nSynthetic image bytes\r\n"
        ));
    }
    raw.push_str("--cid-scope--\r\n");
    raw
}

#[test]
fn ac04_cid_diagnostics_report_duplicates_without_exposing_identifiers() {
    for (ids, duplicate) in [
        (vec!["private-cid", "private-cid"], true),
        (vec!["private-cid", "different-cid"], false),
        (vec!["private-cid", "PRIVATE-CID"], false),
        (vec![], false),
    ] {
        let raw = cid_message(&ids);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw.as_bytes()).unwrap();
        assert_eq!(diagnostics.duplicate_content_id, duplicate);
        assert_eq!(message.attachment_count(), ids.len());
        assert_eq!(message.raw_message.as_ref(), raw.as_bytes());
        assert!(!format!("{diagnostics:?}").contains("private-cid"));
        assert_eq!(
            mime_poc::parse(raw.as_bytes()).unwrap().attachment_count(),
            ids.len()
        );
    }
}

#[test]
fn ac04_cid_diagnostics_keep_attached_message_namespaces_separate() {
    let inner = "Content-Type: image/png\r\nContent-Disposition: attachment\r\nContent-ID: <same-cid>\r\n\r\nSynthetic inner image";
    let raw = format!(
        "Content-Type: multipart/mixed; boundary=outer\r\n\r\n--outer\r\nContent-Type: image/png\r\nContent-Disposition: attachment\r\nContent-ID: <same-cid>\r\n\r\nSynthetic outer image\r\n--outer\r\nContent-Type: message/rfc822\r\n\r\n{inner}\r\n--outer\r\nContent-Type: message/rfc822\r\n\r\n{inner}\r\n--outer--\r\n"
    );
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw.as_bytes()).unwrap();
    assert!(!diagnostics.duplicate_content_id);
    assert_eq!(message.attachment_count(), 3);
    assert_eq!(
        message
            .parts
            .iter()
            .filter(|part| matches!(part.body, PartType::Message(_)))
            .count(),
        2
    );
}

#[test]
fn ac04_cid_diagnostics_include_duplicates_inside_attached_messages() {
    let raw = format!(
        "Content-Type: message/rfc822\r\nContent-Disposition: attachment\r\n\r\n{}",
        cid_message(&["private-nested-cid", "private-nested-cid"])
    );
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw.as_bytes()).unwrap();
    assert!(diagnostics.duplicate_content_id);
    assert!(!diagnostics.unrecognized_text_charset);
    assert!(!diagnostics.replacement_character_present);
    assert_eq!(message.raw_message.as_ref(), raw.as_bytes());
    let PartType::Message(nested) = &message.parts[0].body else {
        panic!("expected attached message");
    };
    assert_eq!(nested.attachment_count(), 2);
    assert!(!format!("{diagnostics:?}").contains("private-nested-cid"));
}

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
fn ac04_charset_replacement_presence_does_not_prove_decoding_loss() {
    let valid_utf8_replacement =
        b"Content-Type: text/plain; charset=utf-8\r\n\r\nSynthetic \xef\xbf\xbd";
    let (valid, valid_diagnostics) =
        mime_poc::parse_with_diagnostics(valid_utf8_replacement).unwrap();
    assert_eq!(valid.body_text(0).as_deref(), Some("Synthetic \u{fffd}"));
    assert!(valid_diagnostics.replacement_character_present);
    assert!(!valid_diagnostics.unrecognized_text_charset);
    assert!(!valid.parts[0].is_encoding_problem);

    for (charset, malformed_bytes, expected) in [
        ("shift_jis", &b"\x82 X"[..], "Synthetic \u{fffd} X"),
        ("euc-jp", &b"\xa4 X"[..], "Synthetic \u{fffd} X"),
        ("iso-2022-jp", &b"\x1b$BF\x1b(BX"[..], "Synthetic \u{fffd}X"),
    ] {
        let mut raw =
            format!("Content-Type: text/plain; charset={charset}\r\n\r\nSynthetic ").into_bytes();
        raw.extend_from_slice(malformed_bytes);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();

        assert_eq!(message.body_text(0).as_deref(), Some(expected), "{charset}");
        assert!(diagnostics.replacement_character_present, "{charset}");
        assert!(!diagnostics.unrecognized_text_charset, "{charset}");
        assert!(!message.parts[0].is_encoding_problem, "{charset}");
        assert_eq!(message.raw_message.as_ref(), raw, "{charset}");
    }

    let mut odd_utf16 = b"Content-Type: text/plain; charset=utf-16le\r\n\r\n".to_vec();
    for unit in "Synthetic".encode_utf16() {
        odd_utf16.extend_from_slice(&unit.to_le_bytes());
    }
    odd_utf16.push(b'X');
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(&odd_utf16).unwrap();
    assert_eq!(message.body_text(0).as_deref(), Some("Synthetic"));
    assert!(!diagnostics.replacement_character_present);
    assert!(!message.parts[0].is_encoding_problem);
    assert_eq!(message.raw_message.as_ref(), odd_utf16);

    let mut odd_utf16_be = b"Content-Type: text/plain; charset=utf-16be\r\n\r\n".to_vec();
    for unit in "Synthetic".encode_utf16() {
        odd_utf16_be.extend_from_slice(&unit.to_be_bytes());
    }
    odd_utf16_be.push(b'X');
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(&odd_utf16_be).unwrap();
    assert_eq!(message.body_text(0).as_deref(), Some("Synthetic"));
    assert!(!diagnostics.replacement_character_present);
    assert!(!message.parts[0].is_encoding_problem);
    assert_eq!(message.raw_message.as_ref(), odd_utf16_be);

    let mut unpaired_surrogate = b"Content-Type: text/plain; charset=utf-16le\r\n\r\n".to_vec();
    for unit in "Synthetic ".encode_utf16() {
        unpaired_surrogate.extend_from_slice(&unit.to_le_bytes());
    }
    unpaired_surrogate.extend_from_slice(&0xd800_u16.to_le_bytes());
    unpaired_surrogate.extend_from_slice(&u16::from(b'X').to_le_bytes());
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(&unpaired_surrogate).unwrap();
    assert_eq!(message.body_text(0).as_deref(), Some("Synthetic \u{fffd}X"));
    assert!(diagnostics.replacement_character_present);
    assert!(!message.parts[0].is_encoding_problem);
    assert_eq!(message.raw_message.as_ref(), unpaired_surrogate);

    let mut unpaired_surrogate_be = b"Content-Type: text/plain; charset=utf-16be\r\n\r\n".to_vec();
    for unit in "Synthetic ".encode_utf16() {
        unpaired_surrogate_be.extend_from_slice(&unit.to_be_bytes());
    }
    unpaired_surrogate_be.extend_from_slice(&0xd800_u16.to_be_bytes());
    unpaired_surrogate_be.extend_from_slice(&u16::from(b'X').to_be_bytes());
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(&unpaired_surrogate_be).unwrap();
    assert_eq!(message.body_text(0).as_deref(), Some("Synthetic \u{fffd}X"));
    assert!(diagnostics.replacement_character_present);
    assert!(!message.parts[0].is_encoding_problem);
    assert_eq!(message.raw_message.as_ref(), unpaired_surrogate_be);
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
fn ac04_rfc2231_continuations_restore_japanese_names_in_segment_order() {
    for parameters in [
        "filename*0*=utf-8''%E6%97%A5; filename*1*=%E6%9C%AC%E8%AA%9E; filename*2=.bin",
        "filename*2=.bin; filename*1*=%E6%9C%AC%E8%AA%9E; filename*0*=utf-8''%E6%97%A5",
    ] {
        let raw = format!(
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment;\r\n {parameters}\r\nContent-Transfer-Encoding: base64\r\n\r\nAAECAw=="
        );
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw.as_bytes()).unwrap();
        assert_eq!(message.attachment_count(), 1);
        let attachment = message.attachment(0).unwrap();
        assert_eq!(
            attachment.attachment_name(),
            Some("\u{65e5}\u{672c}\u{8a9e}.bin")
        );
        assert_eq!(attachment.contents(), [0, 1, 2, 3]);
        assert_eq!(message.raw_message.as_ref(), raw.as_bytes());
        assert_eq!(diagnostics, mime_poc::MimeDiagnostics::default());
    }
}

#[test]
fn ac04_rfc2231_split_multibyte_name_reports_replacement_without_body_warning() {
    let raw = b"Content-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*0*=utf-8''%E6%97; filename*1*=%A5%E6%9C%AC%E8%AA%9E.bin\r\nContent-Transfer-Encoding: base64\r\n\r\nAAECAw==";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    let attachment = message.attachment(0).unwrap();
    assert_eq!(
        attachment.attachment_name(),
        Some("\u{fffd}\u{fffd}\u{672c}\u{8a9e}.bin")
    );
    assert_eq!(attachment.contents(), [0, 1, 2, 3]);
    assert!(!attachment.is_encoding_problem);
    assert!(diagnostics.attachment_name_replacement_character_present);
    assert!(!diagnostics.replacement_character_present);
    assert!(!diagnostics.unrecognized_text_charset);
    assert_eq!(message.raw_message.as_ref(), raw);
    assert!(!format!("{diagnostics:?}").contains(".bin"));
}

#[test]
fn ac04_attachment_name_replacement_diagnostic_covers_nested_original_character() {
    let raw = b"Content-Type: message/rfc822\r\n\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename*=utf-8''synthetic-%EF%BF%BD.bin\r\n\r\nSynthetic attachment";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    assert!(diagnostics.attachment_name_replacement_character_present);
    assert!(!diagnostics.replacement_character_present);
    assert_eq!(message.raw_message.as_ref(), raw);
    let PartType::Message(nested) = &message.parts[0].body else {
        panic!("expected attached message");
    };
    assert_eq!(
        nested.attachment(0).unwrap().attachment_name(),
        Some("synthetic-\u{fffd}.bin")
    );
}

#[test]
fn ac04_rfc2231_continuations_do_not_make_attachment_paths_safe() {
    for (parameters, expected) in [
        (
            "filename*0*=utf-8''..%2F; filename*1*=synthetic.bin",
            "../synthetic.bin",
        ),
        (
            "filename*0*=utf-8''..%5C; filename*1*=synthetic.bin",
            "..\\synthetic.bin",
        ),
        (
            "filename*0*=utf-8''%2Ftmp%2F; filename*1*=synthetic.bin",
            "/tmp/synthetic.bin",
        ),
    ] {
        let raw = format!(
            "Content-Type: application/octet-stream\r\nContent-Disposition: attachment; {parameters}\r\n\r\nSynthetic attachment"
        );
        let message = mime_poc::parse(raw.as_bytes()).unwrap();
        let attachment = message.attachment(0).unwrap();
        assert_eq!(attachment.attachment_name(), Some(expected));
        assert_eq!(attachment.contents(), b"Synthetic attachment");
        assert_eq!(message.raw_message.as_ref(), raw.as_bytes());
    }
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
fn ac04_quoted_printable_malformed_escapes_can_be_retained_or_dropped_silently() {
    for (body, expected) in [
        (&b"Synthetic =GG suffix"[..], "Synthetic =GG suffix"),
        (&b"Synthetic trailing="[..], "Synthetic trailing"),
        (&b"Synthetic =A"[..], "Synthetic "),
        (&b"Synthetic =\rX suffix"[..], "Synthetic =X suffix"),
    ] {
        let mut raw =
            b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
                .to_vec();
        raw.extend_from_slice(body);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();

        assert_eq!(message.body_text(0).as_deref(), Some(expected));
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_soft_line_breaks_and_whitespace_after_equals() {
    for (body, expected) in [
        (&b"Synthetic=\r\ncontinued"[..], "Syntheticcontinued"),
        (&b"Synthetic=\ncontinued"[..], "Syntheticcontinued"),
        (&b"Synthetic= \r\ncontinued"[..], "Syntheticcontinued"),
        (&b"Synthetic=\t\r\ncontinued"[..], "Syntheticcontinued"),
    ] {
        let mut raw =
            b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
                .to_vec();
        raw.extend_from_slice(body);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();

        assert_eq!(message.body_text(0).as_deref(), Some(expected));
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_hex_octets_and_hard_line_whitespace() {
    for (body, expected) in [
        (&b"Synthetic=3d=3D"[..], "Synthetic=="),
        (
            &b"Synthetic line\r\ncontinued"[..],
            "Synthetic line\r\ncontinued",
        ),
        (
            &b"Synthetic trailing \r\ncontinued"[..],
            "Synthetic trailing\r\ncontinued",
        ),
        (
            &b"Synthetic trailing\t\r\ncontinued"[..],
            "Synthetic trailing\r\ncontinued",
        ),
    ] {
        let mut raw =
            b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
                .to_vec();
        raw.extend_from_slice(body);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();

        assert_eq!(message.body_text(0).as_deref(), Some(expected));
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_long_lines_are_accepted_and_bare_carriage_return_is_dropped() {
    for body in ["x".repeat(76), "x".repeat(77)] {
        let mut raw =
            b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
                .to_vec();
        raw.extend_from_slice(body.as_bytes());
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();

        assert_eq!(message.body_text(0).as_deref(), Some(body.as_str()));
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }

    let raw = b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nSynthetic\rbare carriage return";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    assert_eq!(
        message.body_text(0).as_deref(),
        Some("Syntheticbare carriage return")
    );
    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    assert_eq!(message.raw_message.as_ref(), raw);
    assert_eq!(
        diagnostics,
        mail_client_lib::mime_poc::MimeDiagnostics::default()
    );
}

#[test]
fn ac04_quoted_printable_encoded_and_eof_trailing_whitespace() {
    for (body, expected) in [
        (&b"Synthetic=20"[..], "Synthetic "),
        (&b"Synthetic=09"[..], "Synthetic\t"),
        (&b"Synthetic "[..], "Synthetic "),
        (&b"Synthetic\t"[..], "Synthetic\t"),
    ] {
        let mut raw =
            b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n"
                .to_vec();
        raw.extend_from_slice(body);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();

        assert_eq!(message.body_text(0).as_deref(), Some(expected));
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_mixed_hard_line_endings_reuse_crlf_style() {
    let raw = b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nfirst\r\nsecond\nthird";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    assert_eq!(
        message.body_text(0).as_deref(),
        Some("first\r\nsecond\r\nthird")
    );
    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    assert_eq!(message.raw_message.as_ref(), raw);
    assert_eq!(
        diagnostics,
        mail_client_lib::mime_poc::MimeDiagnostics::default()
    );
}

#[test]
fn ac04_quoted_printable_soft_break_preserves_following_hard_line_style() {
    let raw = b"Content-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nfirst=\ncontinued\r\nlast";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    assert_eq!(
        message.body_text(0).as_deref(),
        Some("firstcontinued\r\nlast")
    );
    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    assert_eq!(message.raw_message.as_ref(), raw);
    assert_eq!(
        diagnostics,
        mail_client_lib::mime_poc::MimeDiagnostics::default()
    );
}

#[test]
fn ac04_quoted_printable_soft_break_before_multipart_boundary_drops_body_octet() {
    for (encoded_body, expected) in [
        (&b"before\r\n"[..], "before"),
        (&b"before=\r\n"[..], "befo"),
    ] {
        let mut raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=qp-boundary\r\n\r\n--qp-boundary\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n".to_vec();
        raw.extend_from_slice(encoded_body);
        raw.extend_from_slice(
            b"--qp-boundary\r\nContent-Type: text/plain\r\n\r\nsecond part\r\n--qp-boundary--\r\n",
        );
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();

        assert_eq!(message.parts.len(), 3);
        let PartType::Text(first_part) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        let PartType::Text(second_part) = &message.parts[2].body else {
            panic!("expected following text part");
        };
        assert_eq!(first_part.as_ref(), expected);
        assert_eq!(second_part.as_ref(), "second part");
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_short_soft_break_before_boundary_corrupts_body() {
    let raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=qp-boundary\r\n\r\n--qp-boundary\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nx=\r\n--qp-boundary\r\nContent-Type: text/plain\r\n\r\nsecond part\r\n--qp-boundary--\r\n";
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        mime_poc::parse_with_diagnostics(raw)
    }));
    if cfg!(debug_assertions) {
        assert!(result.is_err());
    } else {
        let (message, diagnostics) = result
            .expect("optimized parser should not panic")
            .expect("short quoted-printable fixture should parse");
        let PartType::Text(body) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        assert_eq!(body.as_ref(), "x-");
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_boundary_corruption_varies_with_body_length() {
    for length in 1..=4 {
        let body = "x".repeat(length);
        let mut raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=qp-boundary\r\n\r\n--qp-boundary\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n".to_vec();
        raw.extend_from_slice(body.as_bytes());
        raw.extend_from_slice(b"=\r\n--qp-boundary\r\nContent-Type: text/plain\r\n\r\nsecond part\r\n--qp-boundary--\r\n");
        let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            mime_poc::parse_with_diagnostics(&raw)
        }));

        if cfg!(debug_assertions) && length == 1 {
            assert!(parsed.is_err());
            continue;
        }

        let (message, diagnostics) = parsed
            .expect("parser should not panic for this body length")
            .expect("quoted-printable multipart fixture should parse");
        let PartType::Text(decoded) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        let expected = if !cfg!(debug_assertions) && length == 1 {
            format!("{body}-")
        } else {
            "x".repeat(length.saturating_sub(2))
        };
        assert_eq!(decoded.as_ref(), expected);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_soft_break_before_closing_boundary_drops_body_octet() {
    let raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=qp-boundary\r\n\r\n--qp-boundary\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nbefore=\r\n--qp-boundary--\r\n";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    assert_eq!(message.parts.len(), 2);
    let PartType::Text(body) = &message.parts[1].body else {
        panic!("expected quoted-printable text part");
    };
    assert_eq!(body.as_ref(), "befo");
    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    assert_eq!(message.raw_message.as_ref(), raw);
    assert_eq!(
        diagnostics,
        mail_client_lib::mime_poc::MimeDiagnostics::default()
    );
}

#[test]
fn ac04_quoted_printable_soft_break_with_continuation_before_boundary_preserves_body() {
    let raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=qp-boundary\r\n\r\n--qp-boundary\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nbefore=\r\ncontinued\r\n--qp-boundary\r\nContent-Type: text/plain\r\n\r\nsecond part\r\n--qp-boundary--\r\n";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    assert_eq!(message.parts.len(), 3);
    let PartType::Text(first_part) = &message.parts[1].body else {
        panic!("expected quoted-printable text part");
    };
    let PartType::Text(second_part) = &message.parts[2].body else {
        panic!("expected following text part");
    };
    assert_eq!(first_part.as_ref(), "beforecontinued");
    assert_eq!(second_part.as_ref(), "second part");
    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    assert_eq!(message.raw_message.as_ref(), raw);
    assert_eq!(
        diagnostics,
        mail_client_lib::mime_poc::MimeDiagnostics::default()
    );
}

#[test]
fn ac04_quoted_printable_soft_break_before_lf_multipart_boundary_behavior() {
    let raw = b"MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=qp-boundary\n\n--qp-boundary\nContent-Type: text/plain\nContent-Transfer-Encoding: quoted-printable\n\nbefore=\n--qp-boundary\nContent-Type: text/plain\n\nsecond part\n--qp-boundary--\n";
    let (message, diagnostics) = mime_poc::parse_with_diagnostics(raw).unwrap();
    let PartType::Text(first_part) = &message.parts[1].body else {
        panic!("expected quoted-printable text part");
    };
    assert_eq!(first_part.as_ref(), "befor");
    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
    assert_eq!(message.raw_message.as_ref(), raw);
    assert_eq!(
        diagnostics,
        mail_client_lib::mime_poc::MimeDiagnostics::default()
    );
}

#[test]
fn ac04_quoted_printable_whitespace_soft_break_before_boundary_behavior() {
    for (encoded_break, expected) in [
        (&b"=\r\n"[..], "befo"),
        (&b"= \r\n"[..], "befo"),
        (&b"=\t\r\n"[..], "befo"),
    ] {
        let mut raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=qp-boundary\r\n\r\n--qp-boundary\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\nbefore".to_vec();
        raw.extend_from_slice(encoded_break);
        raw.extend_from_slice(
            b"--qp-boundary\r\nContent-Type: text/plain\r\n\r\nsecond part\r\n--qp-boundary--\r\n",
        );
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
        assert_eq!(message.parts.len(), 3);
        let PartType::Text(first_part) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        let PartType::Text(second_part) = &message.parts[2].body else {
            panic!("expected following text part");
        };
        assert_eq!(first_part.as_ref(), expected);
        assert_eq!(second_part.as_ref(), "second part");
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_hard_line_trailing_whitespace_before_boundary() {
    for (encoded_body, expected) in [
        (&b"before \r\n"[..], "before"),
        (&b"before\t\r\n"[..], "before"),
        (&b"before=20\r\n"[..], "before "),
        (&b"before=09\r\n"[..], "before\t"),
    ] {
        let mut raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=qp-boundary\r\n\r\n--qp-boundary\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n".to_vec();
        raw.extend_from_slice(encoded_body);
        raw.extend_from_slice(
            b"--qp-boundary\r\nContent-Type: text/plain\r\n\r\nsecond part\r\n--qp-boundary--\r\n",
        );
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
        assert_eq!(message.parts.len(), 3);
        let PartType::Text(first_part) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        assert_eq!(first_part.as_ref(), expected);
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_lf_whitespace_soft_break_before_boundary_truncates_body() {
    for encoded_break in [&b"=\n"[..], &b"= \n"[..], &b"=\t\n"[..]] {
        let mut raw = b"MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=qp-boundary\n\n--qp-boundary\nContent-Type: text/plain\nContent-Transfer-Encoding: quoted-printable\n\nbefore".to_vec();
        raw.extend_from_slice(encoded_break);
        raw.extend_from_slice(
            b"--qp-boundary\nContent-Type: text/plain\n\nsecond part\n--qp-boundary--\n",
        );
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
        assert_eq!(message.parts.len(), 3);
        let PartType::Text(first_part) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        let PartType::Text(second_part) = &message.parts[2].body else {
            panic!("expected following text part");
        };
        assert_eq!(first_part.as_ref(), "befor");
        assert_eq!(second_part.as_ref(), "second part");
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_lf_soft_break_short_bodies_truncate_without_panic() {
    for encoded_break in [&b"=\n"[..], &b"= \n"[..], &b"=\t\n"[..]] {
        for length in 1..=4 {
            let body = "x".repeat(length);
            let mut raw = b"MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=qp-boundary\n\n--qp-boundary\nContent-Type: text/plain\nContent-Transfer-Encoding: quoted-printable\n\n".to_vec();
            raw.extend_from_slice(body.as_bytes());
            raw.extend_from_slice(encoded_break);
            raw.extend_from_slice(
                b"--qp-boundary\nContent-Type: text/plain\n\nsecond part\n--qp-boundary--\n",
            );
            let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
            assert_eq!(message.parts.len(), 3);
            let PartType::Text(decoded) = &message.parts[1].body else {
                panic!("expected quoted-printable text part");
            };
            let PartType::Text(second_part) = &message.parts[2].body else {
                panic!("expected following text part");
            };
            assert_eq!(decoded.as_ref(), "x".repeat(length - 1));
            assert_eq!(second_part.as_ref(), "second part");
            assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
            assert_eq!(message.raw_message.as_ref(), raw);
            assert_eq!(
                diagnostics,
                mail_client_lib::mime_poc::MimeDiagnostics::default()
            );
        }
    }
}

#[test]
fn ac04_quoted_printable_crlf_whitespace_short_bodies() {
    for encoded_break in [&b"=\r\n"[..], &b"= \r\n"[..], &b"=\t\r\n"[..]] {
        for length in 1..=4 {
            let body = "x".repeat(length);
            let mut raw = b"MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=qp-boundary\r\n\r\n--qp-boundary\r\nContent-Type: text/plain\r\nContent-Transfer-Encoding: quoted-printable\r\n\r\n".to_vec();
            raw.extend_from_slice(body.as_bytes());
            raw.extend_from_slice(encoded_break);
            raw.extend_from_slice(
                b"--qp-boundary\r\nContent-Type: text/plain\r\n\r\nsecond part\r\n--qp-boundary--\r\n",
            );
            let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                mime_poc::parse_with_diagnostics(&raw)
            }));
            if cfg!(debug_assertions) && length == 1 {
                assert!(parsed.is_err());
                continue;
            }

            let (message, diagnostics) = parsed
                .expect("parser should not panic for this body length")
                .expect("quoted-printable multipart fixture should parse");
            assert_eq!(message.parts.len(), 3);
            let PartType::Text(decoded) = &message.parts[1].body else {
                panic!("expected quoted-printable text part");
            };
            let PartType::Text(second_part) = &message.parts[2].body else {
                panic!("expected following text part");
            };
            if cfg!(debug_assertions) {
                assert_eq!(decoded.as_ref(), "x".repeat(length.saturating_sub(2)));
            }
            assert_eq!(second_part.as_ref(), "second part");
            assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
            assert_eq!(message.raw_message.as_ref(), raw);
            assert_eq!(
                diagnostics,
                mail_client_lib::mime_poc::MimeDiagnostics::default()
            );
        }
    }
}

#[test]
fn ac04_quoted_printable_multibyte_short_bodies_are_corrupted_at_boundaries() {
    let bodies = ["é", "日", "😀", "é日", "日é"];
    let crlf_expected = ["", "�", "�", "é�", "日"];
    let lf_expected = ["�", "�", "�", "é�", "日�"];
    for (line_ending, encoded_break, expected) in [
        (&b"\r\n"[..], &b"=\r\n"[..], &crlf_expected[..]),
        (&b"\r\n"[..], &b"= \r\n"[..], &crlf_expected[..]),
        (&b"\r\n"[..], &b"=\t\r\n"[..], &crlf_expected[..]),
        (&b"\n"[..], &b"=\n"[..], &lf_expected[..]),
        (&b"\n"[..], &b"= \n"[..], &lf_expected[..]),
        (&b"\n"[..], &b"=\t\n"[..], &lf_expected[..]),
    ] {
        for (body, expected_body) in bodies.iter().zip(expected) {
            let mut raw = b"MIME-Version: 1.0".to_vec();
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(body.as_bytes());
            raw.extend_from_slice(encoded_break);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"second part");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary--");
            raw.extend_from_slice(line_ending);
            let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
            assert_eq!(message.parts.len(), 3);
            let PartType::Text(decoded) = &message.parts[1].body else {
                panic!("expected quoted-printable text part");
            };
            let PartType::Text(second_part) = &message.parts[2].body else {
                panic!("expected following text part");
            };
            assert_eq!(decoded.as_ref(), *expected_body);
            assert_eq!(second_part.as_ref(), "second part");
            assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
            assert_eq!(message.raw_message.as_ref(), raw);
            assert_eq!(
                diagnostics.replacement_character_present,
                expected_body.contains('�')
            );
            assert!(!diagnostics.unrecognized_text_charset);
            assert!(!diagnostics.duplicate_content_id);
            assert!(!diagnostics.attachment_name_replacement_character_present);
        }
    }
}

#[test]
fn ac04_quoted_printable_encoded_utf8_is_corrupted_at_boundaries() {
    let encoded_bodies = ["=C3=A9", "=E6=97=A5", "=F0=9F=98=80", "=C3=A9=E6=97=A5"];
    let crlf_expected = ["", "�", "�", "é�"];
    let lf_expected = ["�", "�", "�", "é�"];
    for (line_ending, encoded_break, expected) in [
        (&b"\r\n"[..], &b"=\r\n"[..], &crlf_expected[..]),
        (&b"\r\n"[..], &b"= \r\n"[..], &crlf_expected[..]),
        (&b"\r\n"[..], &b"=\t\r\n"[..], &crlf_expected[..]),
        (&b"\n"[..], &b"=\n"[..], &lf_expected[..]),
        (&b"\n"[..], &b"= \n"[..], &lf_expected[..]),
        (&b"\n"[..], &b"=\t\n"[..], &lf_expected[..]),
    ] {
        for (body, expected_body) in encoded_bodies.iter().zip(expected) {
            let mut raw = b"MIME-Version: 1.0".to_vec();
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(body.as_bytes());
            raw.extend_from_slice(encoded_break);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"second part");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary--");
            raw.extend_from_slice(line_ending);
            let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
            assert_eq!(message.parts.len(), 3);
            let PartType::Text(decoded) = &message.parts[1].body else {
                panic!("expected quoted-printable text part");
            };
            let PartType::Text(second_part) = &message.parts[2].body else {
                panic!("expected following text part");
            };
            assert_eq!(decoded.as_ref(), *expected_body);
            assert_eq!(second_part.as_ref(), "second part");
            assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
            assert_eq!(message.raw_message.as_ref(), raw);
            assert_eq!(
                diagnostics.replacement_character_present,
                expected_body.contains('�')
            );
            assert!(!diagnostics.unrecognized_text_charset);
        }
    }
}

#[test]
fn ac04_quoted_printable_split_utf8_encoded_octets_preserve_body() {
    for (line_ending, soft_break) in [
        (&b"\r\n"[..], &b"=\r\n"[..]),
        (&b"\r\n"[..], &b"= \r\n"[..]),
        (&b"\r\n"[..], &b"=\t\r\n"[..]),
        (&b"\n"[..], &b"=\n"[..]),
        (&b"\n"[..], &b"= \n"[..]),
        (&b"\n"[..], &b"=\t\n"[..]),
    ] {
        let mut raw = b"MIME-Version: 1.0".to_vec();
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"--qp-boundary");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"=C3");
        raw.extend_from_slice(soft_break);
        raw.extend_from_slice(b"=A9tail");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"--qp-boundary");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"Content-Type: text/plain");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"second part");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"--qp-boundary--");
        raw.extend_from_slice(line_ending);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
        let PartType::Text(body) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        let PartType::Text(second_part) = &message.parts[2].body else {
            panic!("expected following text part");
        };
        assert_eq!(message.parts.len(), 3);
        assert_eq!(body.as_ref(), "étail");
        assert_eq!(second_part.as_ref(), "second part");
        assert!(!diagnostics.replacement_character_present);
        assert_eq!(message.raw_message.as_ref(), raw);
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert!(!diagnostics.unrecognized_text_charset);
    }
}

#[test]
fn ac04_quoted_printable_encoded_octet_splits_preserve_or_reject_body() {
    let encoded = b"=C3=A9";
    for split in 0..=encoded.len() {
        for (line_ending, soft_break) in [
            (&b"\r\n"[..], &b"=\r\n"[..]),
            (&b"\r\n"[..], &b"= \r\n"[..]),
            (&b"\r\n"[..], &b"=\t\r\n"[..]),
            (&b"\n"[..], &b"=\n"[..]),
            (&b"\n"[..], &b"= \n"[..]),
            (&b"\n"[..], &b"=\t\n"[..]),
        ] {
            let mut raw = b"MIME-Version: 1.0".to_vec();
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(&encoded[..split]);
            raw.extend_from_slice(soft_break);
            raw.extend_from_slice(&encoded[split..]);
            raw.extend_from_slice(b"tail");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"second part");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary--");
            raw.extend_from_slice(line_ending);
            let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                mime_poc::parse_with_diagnostics(&raw)
            }));
            assert!(parsed.is_ok(), "parser panicked at split {split}");
            match split {
                0 | 3 | 6 => {
                    let (message, diagnostics) = parsed.unwrap().unwrap();
                    assert_eq!(message.parts.len(), 3);
                    let PartType::Text(body) = &message.parts[1].body else {
                        panic!("expected quoted-printable text part");
                    };
                    let PartType::Text(second_part) = &message.parts[2].body else {
                        panic!("expected following text part");
                    };
                    assert_eq!(body.as_ref(), "étail");
                    assert_eq!(second_part.as_ref(), "second part");
                    assert!(!diagnostics.replacement_character_present);
                    assert_eq!(
                        diagnostics,
                        mail_client_lib::mime_poc::MimeDiagnostics::default()
                    );
                    assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
                    assert_eq!(message.raw_message.as_ref(), raw);
                }
                _ => {
                    let error = parsed
                        .unwrap()
                        .expect_err("split escape must be incomplete");
                    assert_eq!(error, MimeError::Incomplete);
                    assert!(!error.to_string().contains("tail"));
                }
            }
        }
    }
}

#[test]
fn ac04_quoted_printable_three_byte_utf8_octet_splits_follow_escape_boundaries() {
    let encoded = b"=E6=97=A5";
    for split in 0..=encoded.len() {
        for (line_ending, soft_break) in [
            (&b"\r\n"[..], &b"=\r\n"[..]),
            (&b"\r\n"[..], &b"= \r\n"[..]),
            (&b"\r\n"[..], &b"=\t\r\n"[..]),
            (&b"\n"[..], &b"=\n"[..]),
            (&b"\n"[..], &b"= \n"[..]),
            (&b"\n"[..], &b"=\t\n"[..]),
        ] {
            let mut raw = b"MIME-Version: 1.0".to_vec();
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(&encoded[..split]);
            raw.extend_from_slice(soft_break);
            raw.extend_from_slice(&encoded[split..]);
            raw.extend_from_slice(b"tail");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"second part");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary--");
            raw.extend_from_slice(line_ending);
            let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                mime_poc::parse_with_diagnostics(&raw)
            }));
            assert!(parsed.is_ok(), "parser panicked at split {split}");
            if split % 3 == 0 {
                let (message, diagnostics) = parsed.unwrap().unwrap();
                assert_eq!(message.parts.len(), 3);
                let PartType::Text(body) = &message.parts[1].body else {
                    panic!("expected quoted-printable text part");
                };
                let PartType::Text(second_part) = &message.parts[2].body else {
                    panic!("expected following text part");
                };
                assert_eq!(body.as_ref(), "日tail");
                assert_eq!(second_part.as_ref(), "second part");
                assert_eq!(
                    diagnostics,
                    mail_client_lib::mime_poc::MimeDiagnostics::default()
                );
                assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
                assert_eq!(message.raw_message.as_ref(), raw);
            } else {
                let error = parsed
                    .unwrap()
                    .expect_err("split escape must be incomplete");
                assert_eq!(error, MimeError::Incomplete);
                assert!(!error.to_string().contains("tail"));
            }
        }
    }
}

#[test]
fn ac04_quoted_printable_four_byte_utf8_octet_splits_follow_escape_boundaries() {
    let encoded = b"=F0=9F=98=80";
    for split in 0..=encoded.len() {
        for (line_ending, soft_break) in [
            (&b"\r\n"[..], &b"=\r\n"[..]),
            (&b"\r\n"[..], &b"= \r\n"[..]),
            (&b"\r\n"[..], &b"=\t\r\n"[..]),
            (&b"\n"[..], &b"=\n"[..]),
            (&b"\n"[..], &b"= \n"[..]),
            (&b"\n"[..], &b"=\t\n"[..]),
        ] {
            let mut raw = b"MIME-Version: 1.0".to_vec();
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(&encoded[..split]);
            raw.extend_from_slice(soft_break);
            raw.extend_from_slice(&encoded[split..]);
            raw.extend_from_slice(b"tail");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"second part");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary--");
            raw.extend_from_slice(line_ending);
            let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                mime_poc::parse_with_diagnostics(&raw)
            }));
            assert!(parsed.is_ok(), "parser panicked at split {split}");
            if split % 3 == 0 {
                let (message, diagnostics) = parsed.unwrap().unwrap();
                assert_eq!(message.parts.len(), 3);
                let PartType::Text(body) = &message.parts[1].body else {
                    panic!("expected quoted-printable text part");
                };
                let PartType::Text(second_part) = &message.parts[2].body else {
                    panic!("expected following text part");
                };
                assert_eq!(body.as_ref(), "😀tail");
                assert_eq!(second_part.as_ref(), "second part");
                assert_eq!(
                    diagnostics,
                    mail_client_lib::mime_poc::MimeDiagnostics::default()
                );
                assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
                assert_eq!(message.raw_message.as_ref(), raw);
            } else {
                let error = parsed
                    .unwrap()
                    .expect_err("split escape must be incomplete");
                assert_eq!(error, MimeError::Incomplete);
                assert!(!error.to_string().contains("tail"));
            }
        }
    }
}

#[test]
fn ac04_quoted_printable_adjacent_multibyte_octet_splits_follow_escape_boundaries() {
    let encoded = b"=C3=A9=E6=97=A5";
    for split in 0..=encoded.len() {
        for (line_ending, soft_break) in [
            (&b"\r\n"[..], &b"=\r\n"[..]),
            (&b"\r\n"[..], &b"= \r\n"[..]),
            (&b"\r\n"[..], &b"=\t\r\n"[..]),
            (&b"\n"[..], &b"=\n"[..]),
            (&b"\n"[..], &b"= \n"[..]),
            (&b"\n"[..], &b"=\t\n"[..]),
        ] {
            let mut raw = b"MIME-Version: 1.0".to_vec();
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(&encoded[..split]);
            raw.extend_from_slice(soft_break);
            raw.extend_from_slice(&encoded[split..]);
            raw.extend_from_slice(b"tail");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"second part");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary--");
            raw.extend_from_slice(line_ending);
            let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                mime_poc::parse_with_diagnostics(&raw)
            }));
            assert!(parsed.is_ok(), "parser panicked at split {split}");
            if split % 3 == 0 {
                let (message, diagnostics) = parsed.unwrap().unwrap();
                assert_eq!(message.parts.len(), 3);
                let PartType::Text(body) = &message.parts[1].body else {
                    panic!("expected quoted-printable text part");
                };
                let PartType::Text(second_part) = &message.parts[2].body else {
                    panic!("expected following text part");
                };
                assert_eq!(body.as_ref(), "é日tail");
                assert_eq!(second_part.as_ref(), "second part");
                assert_eq!(
                    diagnostics,
                    mail_client_lib::mime_poc::MimeDiagnostics::default()
                );
                assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
                assert_eq!(message.raw_message.as_ref(), raw);
            } else {
                let error = parsed
                    .unwrap()
                    .expect_err("split escape must be incomplete");
                assert_eq!(error, MimeError::Incomplete);
                assert!(!error.to_string().contains("tail"));
            }
        }
    }
}

#[test]
fn ac04_quoted_printable_consecutive_soft_breaks_preserve_body() {
    for (line_ending, soft_break) in [
        (&b"\r\n"[..], &b"=\r\n"[..]),
        (&b"\r\n"[..], &b"= \r\n"[..]),
        (&b"\r\n"[..], &b"=\t\r\n"[..]),
        (&b"\n"[..], &b"=\n"[..]),
        (&b"\n"[..], &b"= \n"[..]),
        (&b"\n"[..], &b"=\t\n"[..]),
    ] {
        for count in 2..=3 {
            let mut raw = b"MIME-Version: 1.0".to_vec();
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain; charset=utf-8");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"=C3");
            for _ in 0..count {
                raw.extend_from_slice(soft_break);
            }
            raw.extend_from_slice(b"=A9tail");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"Content-Type: text/plain");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"second part");
            raw.extend_from_slice(line_ending);
            raw.extend_from_slice(b"--qp-boundary--");
            raw.extend_from_slice(line_ending);
            let parsed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                mime_poc::parse_with_diagnostics(&raw)
            }));
            let (message, diagnostics) = parsed
                .expect("parser should not panic on repeated soft breaks")
                .unwrap();
            assert_eq!(message.parts.len(), 3);
            let PartType::Text(body) = &message.parts[1].body else {
                panic!("expected quoted-printable text part");
            };
            let PartType::Text(second_part) = &message.parts[2].body else {
                panic!("expected following text part");
            };
            assert_eq!(body.as_ref(), "étail");
            assert_eq!(second_part.as_ref(), "second part");
            assert_eq!(
                diagnostics,
                mail_client_lib::mime_poc::MimeDiagnostics::default()
            );
            assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
            assert_eq!(message.raw_message.as_ref(), raw);
        }
    }
}

#[test]
fn ac04_quoted_printable_mixed_line_endings_truncate_by_soft_break_style() {
    for (boundary_line_ending, soft_break, expected_body) in [
        (&b"\r\n"[..], &b"=\n"[..], "befor"),
        (&b"\n"[..], &b"=\r\n"[..], "befo"),
        (&b"\r\n"[..], &b"= \n"[..], "befor"),
        (&b"\r\n"[..], &b"=\t\n"[..], "befor"),
        (&b"\n"[..], &b"= \r\n"[..], "befo"),
        (&b"\n"[..], &b"=\t\r\n"[..], "befo"),
    ] {
        let mut raw = b"MIME-Version: 1.0".to_vec();
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(b"--qp-boundary");
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(b"Content-Type: text/plain");
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(b"before");
        raw.extend_from_slice(soft_break);
        raw.extend_from_slice(b"--qp-boundary");
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(b"Content-Type: text/plain");
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(b"second part");
        raw.extend_from_slice(boundary_line_ending);
        raw.extend_from_slice(b"--qp-boundary--");
        raw.extend_from_slice(boundary_line_ending);
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
        assert_eq!(message.parts.len(), 3);
        let PartType::Text(first_part) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        let PartType::Text(second_part) = &message.parts[2].body else {
            panic!("expected following text part");
        };
        assert_eq!(first_part.as_ref(), expected_body);
        assert_eq!(second_part.as_ref(), "second part");
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_lf_soft_break_before_closing_boundary_truncates_body() {
    for encoded_break in [&b"=\n"[..], &b"= \n"[..], &b"=\t\n"[..]] {
        let mut raw = b"MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=qp-boundary\n\n--qp-boundary\nContent-Type: text/plain\nContent-Transfer-Encoding: quoted-printable\n\nbefore".to_vec();
        raw.extend_from_slice(encoded_break);
        raw.extend_from_slice(b"--qp-boundary--\n");
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
        assert_eq!(message.parts.len(), 2);
        let PartType::Text(body) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        assert_eq!(body.as_ref(), "befor");
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
}

#[test]
fn ac04_quoted_printable_closing_boundary_at_eof_truncates_body() {
    for (line_ending, encoded_break, expected_body) in [
        (&b"\r\n"[..], &b"=\r\n"[..], "befo"),
        (&b"\r\n"[..], &b"= \r\n"[..], "befo"),
        (&b"\r\n"[..], &b"=\t\r\n"[..], "befo"),
        (&b"\n"[..], &b"=\n"[..], "befor"),
        (&b"\n"[..], &b"= \n"[..], "befor"),
        (&b"\n"[..], &b"=\t\n"[..], "befor"),
    ] {
        let mut raw = b"MIME-Version: 1.0".to_vec();
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"Content-Type: multipart/mixed; boundary=qp-boundary");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"--qp-boundary");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"Content-Type: text/plain");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"Content-Transfer-Encoding: quoted-printable");
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(line_ending);
        raw.extend_from_slice(b"before");
        raw.extend_from_slice(encoded_break);
        raw.extend_from_slice(b"--qp-boundary--");
        let (message, diagnostics) = mime_poc::parse_with_diagnostics(&raw).unwrap();
        assert_eq!(message.parts.len(), 2);
        let PartType::Text(body) = &message.parts[1].body else {
            panic!("expected quoted-printable text part");
        };
        assert_eq!(body.as_ref(), expected_body);
        assert!(message.parts.iter().all(|part| !part.is_encoding_problem));
        assert_eq!(message.raw_message.as_ref(), raw);
        assert_eq!(
            diagnostics,
            mail_client_lib::mime_poc::MimeDiagnostics::default()
        );
    }
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
