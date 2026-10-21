use imap_codec::{
    ResponseCodec,
    decode::{Decoder, ResponseDecodeError},
    imap_types::{
        fetch::MessageDataItem,
        response::{Data, Response, Status},
    },
};
use mail_client_lib::mime_poc::MAX_RAW_BYTES;

use super::SOURCE;

#[test]
fn ac04_codec_reports_literal_length_at_header_boundary_without_body_buffer() {
    let codec = ResponseCodec::default();
    let limit = u32::try_from(MAX_RAW_BYTES).unwrap();
    for declared in [0, limit - 1, limit, limit + 1, u32::MAX] {
        let header = format!("* 1 FETCH (UID 8 BODY[] {{{declared}}}\r\n");
        assert!(header.len() < 64);
        for end in 0..header.len() {
            assert_eq!(
                codec.decode(&header.as_bytes()[..end]),
                Err(ResponseDecodeError::Incomplete),
                "declaration must be complete before deciding its length"
            );
        }
        let Err(ResponseDecodeError::LiteralFound { length }) = codec.decode(header.as_bytes())
        else {
            panic!("expected literal declaration");
        };
        assert_eq!(length, declared);
        assert_eq!(length > limit, declared > limit);
    }
}

#[test]
fn ac04_codec_limitation_coalesced_partial_literal_does_not_report_declared_length() {
    let codec = ResponseCodec::default();
    let declared = MAX_RAW_BYTES + 1;
    let mut input = format!("* 1 FETCH (UID 8 BODY[] {{{declared}}}\r\n").into_bytes();
    assert_eq!(
        codec.decode(&input),
        Err(ResponseDecodeError::LiteralFound {
            length: u32::try_from(declared).unwrap(),
        })
    );
    input.push(b'x');
    assert_eq!(codec.decode(&input), Err(ResponseDecodeError::Incomplete));
}

#[test]
fn ac04_codec_preserves_body_bytes_and_keeps_tagged_status_as_separate_response() {
    let codec = ResponseCodec::default();
    for status in ["OK", "NO", "BAD"] {
        let mut input = format!("* 1 FETCH (UID 8 BODY[] {{{}}}\r\n", SOURCE.len()).into_bytes();
        input.extend_from_slice(SOURCE);
        input.extend_from_slice(b")\r\n");
        let completion = format!("A0002 {status} synthetic completion\r\n");
        input.extend_from_slice(completion.as_bytes());
        let (remaining, response) = codec.decode(&input).unwrap();
        assert_eq!(remaining, completion.as_bytes());
        let Response::Data(Data::Fetch { seq, items }) = response else {
            panic!("expected FETCH response");
        };
        assert_eq!(seq.get(), 1);
        let items = items.as_ref();
        assert_eq!(items.len(), 2);
        assert!(matches!(items[0], MessageDataItem::Uid(uid) if uid.get() == 8));
        let MessageDataItem::BodyExt {
            section,
            origin,
            data,
        } = &items[1]
        else {
            panic!("expected BODY[]");
        };
        assert!(section.is_none());
        assert!(origin.is_none());
        assert_eq!(data.0.as_ref().unwrap().as_ref(), SOURCE);

        let (remaining, response) = codec.decode(remaining).unwrap();
        assert!(remaining.is_empty());
        let tag = match (status, response) {
            ("OK", Response::Status(Status::Ok { tag, .. }))
            | ("NO", Response::Status(Status::No { tag, .. }))
            | ("BAD", Response::Status(Status::Bad { tag, .. })) => tag,
            _ => panic!("tagged status must not be discarded or changed"),
        };
        assert_eq!(tag.unwrap().as_ref(), "A0002");
    }
}

#[test]
fn ac04_codec_rejects_invalid_or_overflowed_literal_declarations() {
    let codec = ResponseCodec::default();
    for length in ["-1", "4294967296", "18446744073709551615", "x"] {
        let input = format!("* 1 FETCH (UID 8 BODY[] {{{length}}}\r\n");
        assert_eq!(
            codec.decode(input.as_bytes()),
            Err(ResponseDecodeError::Failed)
        );
    }
}
