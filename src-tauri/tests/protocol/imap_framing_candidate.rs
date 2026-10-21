use imap_codec_framing::{
    ResponseCodec,
    fragmentizer::{FragmentInfo, Fragmentizer},
};
use mail_client_lib::mime_poc::MAX_RAW_BYTES;

use super::SOURCE;

const INPUT_CHUNK_BYTES: usize = 1024;

#[derive(Debug, PartialEq, Eq)]
enum FramingError {
    LiteralTooLarge,
    ResponseTooLarge,
    Decode,
}

struct BoundedFramingProbe {
    fragments: Fragmentizer,
    max_literal_bytes: u32,
    max_response_bytes: u32,
}

impl BoundedFramingProbe {
    fn new(max_literal_bytes: u32, max_response_bytes: u32) -> Self {
        Self {
            fragments: Fragmentizer::new(max_response_bytes),
            max_literal_bytes,
            max_response_bytes,
        }
    }

    fn feed(&mut self, input: &[u8]) -> Result<Vec<Vec<u8>>, FramingError> {
        let mut responses = Vec::new();
        // enqueue_bytes itself is unbounded; drain each bounded input chunk first.
        for chunk in input.chunks(INPUT_CHUNK_BYTES) {
            self.fragments.enqueue_bytes(chunk);
            loop {
                let fragment = self.fragments.progress();
                if self.fragments.is_max_message_size_exceeded() {
                    return Err(FramingError::ResponseTooLarge);
                }
                let Some(fragment) = fragment else {
                    break;
                };
                if let FragmentInfo::Line {
                    end,
                    announcement: Some(announcement),
                    ..
                } = fragment
                {
                    if announcement.length > self.max_literal_bytes {
                        return Err(FramingError::LiteralTooLarge);
                    }
                    if u32::try_from(end)
                        .ok()
                        .and_then(|end| end.checked_add(announcement.length))
                        .is_none_or(|total| total > self.max_response_bytes)
                    {
                        return Err(FramingError::ResponseTooLarge);
                    }
                }
                if self.fragments.is_message_complete() {
                    self.fragments
                        .decode_message(&ResponseCodec::default())
                        .map_err(|_| FramingError::Decode)?;
                    responses.push(self.fragments.message_bytes().to_vec());
                }
            }
        }
        Ok(responses)
    }
}

fn fetch_response(body: &[u8]) -> Vec<u8> {
    let mut response = format!("* 1 FETCH (UID 8 BODY[] {{{}}}\r\n", body.len()).into_bytes();
    response.extend_from_slice(body);
    response.extend_from_slice(b")\r\n");
    response
}

#[test]
fn ac04_framing_handles_fragmented_and_coalesced_literal_and_tagged_response() {
    let body_response = fetch_response(SOURCE);
    let completion = b"A0002 OK synthetic completion\r\n";
    let mut input = body_response.clone();
    input.extend_from_slice(completion);
    for chunk_size in [1, 17, input.len()] {
        let mut probe = BoundedFramingProbe::new(512, 1024);
        let mut responses = Vec::new();
        for chunk in input.chunks(chunk_size) {
            responses.extend(probe.feed(chunk).unwrap());
        }
        assert_eq!(responses, [body_response.clone(), completion.to_vec()]);
    }
}

#[test]
fn ac04_framing_checks_literal_boundaries_before_consuming_coalesced_body() {
    let limit = u32::try_from(MAX_RAW_BYTES).unwrap();
    for declared in [limit - 1, limit, limit + 1, u32::MAX] {
        let header = format!("* 1 FETCH (UID 8 BODY[] {{{declared}}}\r\n");
        let mut input = header.as_bytes().to_vec();
        input.push(b'x');
        for chunk_size in [1, 17, input.len()] {
            let mut probe = BoundedFramingProbe::new(limit, limit + 4096);
            let result: Result<Vec<_>, _> = input
                .chunks(chunk_size)
                .map(|chunk| probe.feed(chunk))
                .collect();
            if declared > limit {
                assert_eq!(result, Err(FramingError::LiteralTooLarge));
                assert_eq!(probe.fragments.message_bytes(), header.as_bytes());
            } else {
                assert!(result.unwrap().iter().all(Vec::is_empty));
                assert_eq!(probe.fragments.message_bytes(), input);
            }
        }
    }
    for size in [0, 31, 32, 33] {
        let input = fetch_response(&vec![b'x'; size]);
        let mut probe = BoundedFramingProbe::new(32, 128);
        if size <= 32 {
            assert_eq!(probe.feed(&input).unwrap(), [input]);
        } else {
            assert_eq!(probe.feed(&input), Err(FramingError::LiteralTooLarge));
        }
    }
}

#[test]
fn ac04_framing_caps_total_response_including_multiple_literals_and_long_lines() {
    let mut response = b"* 1 FETCH (BODY[1] {64}\r\n".to_vec();
    response.extend_from_slice(&[b'x'; 64]);
    response.extend_from_slice(b" BODY[2] {64}\r\n");
    response.extend_from_slice(&[b'y'; 64]);
    response.extend_from_slice(b")\r\n");
    let exact_size = u32::try_from(response.len()).unwrap();
    for limit in [exact_size - 1, exact_size, exact_size + 1] {
        for chunk_size in [1, 17, response.len()] {
            let mut probe = BoundedFramingProbe::new(64, limit);
            let result: Result<Vec<_>, _> = response
                .chunks(chunk_size)
                .map(|chunk| probe.feed(chunk))
                .collect();
            if limit < exact_size {
                assert_eq!(result, Err(FramingError::ResponseTooLarge));
            } else {
                assert_eq!(
                    result.unwrap().into_iter().flatten().collect::<Vec<_>>(),
                    [response.clone()]
                );
            }
        }
    }
    let mut too_long = BoundedFramingProbe::new(64, 128);
    assert_eq!(
        too_long.feed(&response),
        Err(FramingError::ResponseTooLarge)
    );
    assert!(too_long.fragments.message_bytes().len() <= 128);

    let mut line = BoundedFramingProbe::new(64, 128);
    assert_eq!(
        line.feed(&[b'x'; 4096]),
        Err(FramingError::ResponseTooLarge)
    );
    assert_eq!(line.fragments.message_bytes().len(), 128);
}

#[test]
fn ac04_framing_does_not_accept_truncated_or_invalid_input_as_a_response() {
    let mut truncated = BoundedFramingProbe::new(64, 128);
    assert!(
        truncated
            .feed(b"* 1 FETCH (BODY[] {4}\r\nab")
            .unwrap()
            .is_empty()
    );
    assert!(!truncated.fragments.is_message_complete());
    for input in [
        &b"* 1 FETCH (BODY[] {4294967296}\r\n"[..],
        &b"* 1 FETCH (BODY[] {-1}\r\n"[..],
        &b"* 1 FETCH (BODY[] {x}\r\n"[..],
    ] {
        let mut probe = BoundedFramingProbe::new(64, 128);
        assert_eq!(probe.feed(input), Err(FramingError::Decode));
    }
}
