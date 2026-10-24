#![no_main]

use std::io;

use libfuzzer_sys::fuzz_target;

#[path = "../../src/mime_bounded_poc.rs"]
#[allow(dead_code)]
mod mime_bounded_poc;

use mime_bounded_poc::{DecodeBudget, MimeDocument, MimePartKind};

fuzz_target!(|data: &[u8]| {
    let _ = mime_bounded_poc::Message::parse(data);

    let Ok(document) = MimeDocument::parse(data) else {
        return;
    };

    for (index, part) in document.parts().iter().enumerate() {
        let headers = part.header_range();
        let body = part.body_range();
        assert!(headers.start <= headers.end && headers.end <= data.len());
        assert!(body.start <= body.end && body.end <= data.len());
        assert!(part.parent().is_none_or(|parent| parent < index));

        if part.kind() != MimePartKind::Multipart {
            let mut sink = io::sink();
            let _ = document.decode_part_to_with_diagnostics(
                index,
                false,
                &mut DecodeBudget::new(),
                &mut sink,
            );
            let _ = document.decode_text_part_to_with_diagnostics(
                index,
                false,
                &mut DecodeBudget::new(),
                &mut sink,
            );
        }
    }
});
