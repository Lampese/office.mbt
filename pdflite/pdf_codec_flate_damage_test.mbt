// What the readers make of Flate data that is not exactly one zlib stream:
// the decoder of a stream object, which is handed the bytes that `/Length`
// or the search for `endstream` gave it, and the reader of an inline image,
// which finds the end of the data by the length of the zlib stream. Bytes
// behind a complete stream are tolerated (a `/Length` that takes in the end
// of line or more, a repaired `endstream`); anything else that is not a
// complete stream with its checksum is `InvalidFlateData`. The package
// `flate` has the same for every small damage to a stream
// (`flate/pdf_flate_pins_wbtest.mbt`); this is that the readers pass it on.

///|
/// Decoded bytes as text: printable ASCII as it is, a line end as `/`,
/// anything else as `?`.
fn flate_text_for_test(bytes : BytesView) -> String {
  let text = StringBuilder()
  for byte in bytes {
    let value = byte.to_int()
    text.write_char(
      if value == 10 {
        '/'
      } else if value >= 0x20 && value < 0x7F {
        value.unsafe_to_char()
      } else {
        '?'
      },
    )
  }
  text.to_string()
}

///|
/// What `pdf_decode_stream` makes of a stream object with `data` and the
/// filter `/FlateDecode`: the decoded text, or the name of the error.
fn flate_stream_verdict(data : Bytes) -> String {
  let stream = @syntax.pdf_stream(
    @syntax.pdf_dictionary([
      (codec_stream_name_for_test("/Length"), PdfInteger(data.length())),
      (
        codec_stream_name_for_test("/Filter"),
        PdfNameObject(codec_stream_name_for_test("/FlateDecode")),
      ),
    ]),
    StreamGot(data),
  )
  try @pdflite.pdf_decode_stream(stream) catch {
    InvalidFlateData => "InvalidFlateData"
    FlateOutputLimitExceeded(_) => "FlateOutputLimitExceeded"
    _ => "another error"
  } noraise {
    PdfStreamObject({ data: StreamGot(decoded), .. }) =>
      "decoded \{decoded.length()} bytes (\{flate_text_for_test(decoded)})"
    _ => "not a decoded stream"
  }
}

///|
/// What the content parser makes of an inline image whose data is `data`
/// with `tail` behind it: the decoded text of the image and the number of
/// operators, or the name of the error.
fn flate_inline_verdict(data : Bytes, tail : String) -> String {
  let content = content_inline_concat_for_test([
    content_inline_bytes_for_test("BI /W 12 /H 1 /CS /G /BPC 8 /F /Fl ID "),
    data,
    content_inline_bytes_for_test(tail),
  ])
  try @pdflite.pdf_parse_content_ops_from_bytes(content) catch {
    InvalidFlateData => "InvalidFlateData"
    _ => "another error"
  } noraise {
    [Op_InlineImage(_, _, decoded), .. rest] =>
      "image \{flate_text_for_test(decoded)}, \{rest.length()} more"
    ops => "\{ops.length()} operators, no image first"
  }
}

///|
test "Flate data of a stream: bytes behind it, cut, and damaged" {
  let text = codec_stream_ascii_for_test("BT /F1 12 Tf (Hello) Tj ET\n")
  let encoded = @flate.pdf_flate_encode(text)
  let n = encoded.length()
  let join = content_inline_concat_for_test
  let flipped = encoded.to_fixedarray()
  flipped[n / 2] = flipped[n / 2] ^ b'\x10'
  let checksum = encoded.to_fixedarray()
  checksum[n - 1] = checksum[n - 1] ^ b'\x01'
  let header = encoded.to_fixedarray()
  header[0] = b'\x79'
  let cases : Array[(String, Bytes)] = [
    ("the stream", encoded),
    ("an end of line behind it", join([encoded, b"\r\n"])),
    ("endstream behind it", join([encoded, b"\nendstream\nendobj\n"])),
    ("the stream twice", join([encoded, encoded])),
    ("a megabyte behind it", join([encoded, Bytes::make(1 << 20, b'\xA5')])),
    ("without its last byte", encoded[:n - 1].to_owned()),
    ("without its checksum", encoded[:n - 4].to_owned()),
    ("half of it", encoded[:n / 2].to_owned()),
    ("its header alone", encoded[:2].to_owned()),
    ("one byte", encoded[:1].to_owned()),
    ("no bytes", b""),
    ("a bit flipped in the middle", Bytes::from_array(flipped)),
    ("a bit flipped in the checksum", Bytes::from_array(checksum)),
    ("another method in the header", Bytes::from_array(header)),
    (
      "bytes before the checksum",
      join([encoded[:n - 4].to_owned(), b"\r\n", encoded[n - 4:].to_owned()]),
    ),
    ("an end of line before it", join([b"\n", encoded])),
    ("a preset dictionary", b"\x78\x20\x00\x00\x00\x01\x03\x00\x00\x00\x00\x01"),
    ("raw DEFLATE without a header", encoded[2:n - 4].to_owned()),
  ]
  let report = StringBuilder()
  for entry in cases {
    let (name, data) = entry
    report.write_string("\{name}: \{flate_stream_verdict(data)}\n")
  }
  inspect(
    report.to_string(),
    content=(
      #|the stream: decoded 27 bytes (BT /F1 12 Tf (Hello) Tj ET/)
      #|an end of line behind it: decoded 27 bytes (BT /F1 12 Tf (Hello) Tj ET/)
      #|endstream behind it: decoded 27 bytes (BT /F1 12 Tf (Hello) Tj ET/)
      #|the stream twice: decoded 27 bytes (BT /F1 12 Tf (Hello) Tj ET/)
      #|a megabyte behind it: decoded 27 bytes (BT /F1 12 Tf (Hello) Tj ET/)
      #|without its last byte: InvalidFlateData
      #|without its checksum: InvalidFlateData
      #|half of it: InvalidFlateData
      #|its header alone: InvalidFlateData
      #|one byte: InvalidFlateData
      #|no bytes: decoded 0 bytes ()
      #|a bit flipped in the middle: InvalidFlateData
      #|a bit flipped in the checksum: InvalidFlateData
      #|another method in the header: InvalidFlateData
      #|bytes before the checksum: InvalidFlateData
      #|an end of line before it: InvalidFlateData
      #|a preset dictionary: InvalidFlateData
      #|raw DEFLATE without a header: InvalidFlateData
      #|
    ),
  )
}

///|
test "Flate data of an inline image: where it ends, cut, and damaged" {
  let encoded = @flate.pdf_flate_encode(
    content_inline_bytes_for_test("EI Q EI\nEI Q"),
  )
  let n = encoded.length()
  let flipped = encoded.to_fixedarray()
  flipped[n - 6] = flipped[n - 6] ^ b'\x04'
  let report = StringBuilder()
  for
    entry in [
      ("the data and EI", encoded, "\nEI Q"),
      ("the data and EI at once", encoded, "EI Q"),
      ("two operators behind it", encoded, " EI Q q"),
      ("nothing behind it", encoded, ""),
      ("no EI behind it", encoded, "\nQ"),
      ("cut", encoded[:n - 3].to_owned(), "\nEI Q"),
      ("a bit flipped", Bytes::from_array(flipped), "\nEI Q"),
    ] {
    let (name, data, tail) = entry
    report.write_string("\{name}: \{flate_inline_verdict(data, tail)}\n")
  }
  inspect(
    report.to_string(),
    content=(
      #|the data and EI: image EI Q EI/EI Q, 1 more
      #|the data and EI at once: image EI Q EI/EI Q, 1 more
      #|two operators behind it: image EI Q EI/EI Q, 2 more
      #|nothing behind it: another error
      #|no EI behind it: another error
      #|cut: InvalidFlateData
      #|a bit flipped: InvalidFlateData
      #|
    ),
  )
}
