///|
/// Encode borrowed bytes as a zlib-wrapped Flate stream.
/// Levels outside `0..9` raise `InvalidFlateData`.
pub fn pdf_flate_encode_view_with_level(
  data : BytesView,
  level : Int32,
) -> @core.PdfBytes raise @core.PdfError {
  guard level >= 0 && level <= 9 else { raise InvalidFlateData }
  pdf_flate_encode_stream(data, level)
}

///|
/// Encode borrowed bytes with the default compression level, 6.
pub fn pdf_flate_encode_view(data : BytesView) -> @core.PdfBytes {
  pdf_flate_encode_stream(data, 6)
}

///|
/// Encode owned bytes as a zlib-wrapped Flate stream.
/// Levels outside `0..9` raise `InvalidFlateData`.
pub fn pdf_flate_encode_with_level(
  data : @core.PdfBytes,
  level : Int32,
) -> @core.PdfBytes raise @core.PdfError {
  pdf_flate_encode_view_with_level(data, level)
}

///|
/// Encode owned bytes with the default compression level, 6.
pub fn pdf_flate_encode(data : @core.PdfBytes) -> @core.PdfBytes {
  pdf_flate_encode_view(data)
}

///|
/// One reusable encoder per level. An encoder allocates about half a MiB of
/// window and match-finder tables, which dominates the cost of the many small
/// streams in a PDF; `reset` keeps them and yields exactly the output of a
/// fresh encoder. Encoding never suspends or calls back, so uses of a cached
/// encoder cannot overlap, and an encode abandoned by a panic is undone by
/// the next `reset`.
let pdf_flate_encoders : FixedArray[@zlib.Encoder?] = FixedArray::make(10, None)

///|
/// What one step of the decoder may add to its output, and the size of the
/// array that an encode or a decode writes into first.
const PDF_FLATE_WINDOW : Int32 = 32768

///|
/// The array that every encode and every decode writes into first, and the
/// only one for an output that fits it, which nearly every stream of a PDF
/// does. Neither suspends or calls back, so uses cannot overlap (see
/// `pdf_flate_encoders`). It never leaves this file: a result is a copy.
let pdf_flate_scratch : FixedArray[Byte] = FixedArray::make(
  PDF_FLATE_WINDOW,
  b'\x00',
)

///|
/// `output` with room for `needed` bytes: twice the size where that is
/// enough, with the first `length` bytes copied. The shared array is left
/// as it is; the result is the caller's.
fn pdf_flate_grow(
  output : FixedArray[Byte],
  length : Int32,
  needed : Int32,
) -> FixedArray[Byte] {
  let doubled = if output.length() <= 0x3FFF_FFFF {
    output.length() * 2
  } else {
    0x7FFF_FFFF
  }
  FixedArray::make_and_blit(
    output,
    allocate_len=doubled.max(needed),
    init=b'\x00',
    len=length,
  )
}

///|
fn pdf_flate_encoder(level : Int32) -> @zlib.Encoder {
  match pdf_flate_encoders[level] {
    Some(encoder) => {
      encoder.reset()
      encoder
    }
    None => {
      let encoder = @zlib.Encoder(level~)
      pdf_flate_encoders[level] = Some(encoder)
      encoder
    }
  }
}

///|
/// The stream of the streaming encoder at `level`. It is a function of the
/// data and the level, and not of the arrays its output is drained into
/// (`flate/pdf_flate_pins_wbtest.mbt` holds the bytes): the encoder writes
/// into the free end of one array, the shared one first and a larger one
/// when little room is left, and the result is one copy of what it wrote.
///
/// (The one-shot `@zlib.compress` plans its blocks over the whole input and
/// gives other, slightly smaller streams. Every PDF would change with it.)
fn pdf_flate_encode_stream(data : BytesView, level : Int32) -> Bytes {
  let encoder = pdf_flate_encoder(level)
  let mut output = pdf_flate_scratch
  let mut length = 0
  for pos = 0 {
    let status = encoder.step(
      data[pos:],
      output.mut_view(start=length),
      action=Finish,
    )
    length = length + encoder.last_produced()
    if status is Done {
      break Bytes::from_array(output[:length])
    }
    // A step takes one block of the input, 16 KiB, and writes what it
    // compresses to: where there is less room than a block of text needs,
    // or the step ran out of it, the next array is made now.
    if status is NeedMoreOutput || output.length() - length < 4096 {
      guard length <= 0x7FFF_FFFF - PDF_FLATE_WINDOW else {
        abort("pdf_flate_encode: the stream does not fit an array")
      }
      output = pdf_flate_grow(output, length, length + PDF_FLATE_WINDOW)
    }
    continue pos + encoder.last_consumed()
  }
}

///|
/// Decode the first zlib stream. Empty input returns empty output.
/// Trailing bytes are ignored, preserving the native decoder's tolerance for
/// PDF repair paths that recover a stream by scanning damaged end markers.
/// Malformed streams and preset dictionaries raise `InvalidFlateData`.
/// Output exceeding 1 GiB raises `FlateOutputLimitExceeded`.
pub fn pdf_flate_decode_view(
  data : BytesView,
) -> @core.PdfBytes raise @core.PdfError {
  let (decoded, _) = pdf_flate_decode_view_prefix(data)
  decoded
}

///|
/// Decode the first zlib stream, with the same rules as the borrowed API.
pub fn pdf_flate_decode(
  data : @core.PdfBytes,
) -> @core.PdfBytes raise @core.PdfError {
  pdf_flate_decode_view(data)
}

///|
/// Decode the first zlib stream and return its encoded length, including the
/// header and checksum. Bytes after that stream remain available to the caller.
/// Empty input returns `(b"", 0)`; output is limited to 1 GiB.
pub fn pdf_flate_decode_view_prefix(
  data : BytesView,
) -> (@core.PdfBytes, Int32) raise @core.PdfError {
  pdf_flate_decode_prefix_limited(data, 1 << 30)
}

///|
/// The decoder of every stream: `reset` keeps its window and its tables,
/// which are more than most streams of a PDF decode to. Uses cannot overlap
/// (see `pdf_flate_encoders`), and a decode that an error or the limit
/// ended is undone by the next `reset`.
let pdf_flate_inflater : Ref[@deflate.Inflater?] = Ref(None)

///|
fn pdf_flate_fresh_inflater() -> @deflate.Inflater {
  match pdf_flate_inflater.val {
    Some(inflater) => {
      inflater.reset()
      inflater
    }
    None => {
      let inflater = @deflate.Inflater()
      pdf_flate_inflater.val = Some(inflater)
      inflater
    }
  }
}

///|
/// The zlib stream (RFC 1950) at the start of `data` and its length, if it
/// is one and decodes to at most `max_output` bytes: two bytes of header,
/// the DEFLATE stream, and the Adler-32 of the decoded bytes; what follows
/// is not looked at. `None` for anything else, without saying what is wrong
/// (the caller asks `pdf_flate_decode_checked`).
///
/// The DEFLATE stream is decoded by the raw inflater, which takes the input
/// as it is (`@zlib.Decoder` is made per stream and copies its input 64 KiB
/// at a time), into the free end of one array, the shared one first.
fn pdf_flate_decode_valid(
  data : BytesView,
  max_output : Int32,
) -> (Bytes, Int32)? {
  let size = data.length()
  guard size >= 2 else { return None }
  let cmf = data[0].to_int()
  let flg = data[1].to_int()
  // Method 8 with a window of at most 32 KiB, the check of the two bytes,
  // and no preset dictionary, which a PDF has no place for.
  guard (cmf & 0x0F) == 8 &&
    cmf >> 4 <= 7 &&
    (cmf * 256 + flg) % 31 == 0 &&
    (flg & 0x20) == 0 else {
    return None
  }
  let inflater = pdf_flate_fresh_inflater()
  let mut output = pdf_flate_scratch
  let mut total = 0
  for pos = 2 {
    // There is room for a window: the shared array is one, and an array
    // with less room is replaced below before the next step.
    let status = inflater.step(
      data[pos:],
      output.mut_view(start=total, end=total + PDF_FLATE_WINDOW),
      end=true,
    ) catch {
      InflateError(_, _) => return None
    }
    total = total + inflater.last_produced()
    guard total <= max_output else { return None }
    let pos = pos + inflater.last_consumed()
    guard status is Done else {
      // With `end=true` a step that lacks input raises: the window is full
      // and the stream goes on.
      if output.length() - total < PDF_FLATE_WINDOW {
        guard total <= 0x7FFF_FFFF - PDF_FLATE_WINDOW else { return None }
        output = pdf_flate_grow(output, total, total + PDF_FLATE_WINDOW)
      }
      continue pos
    }
    // The four bytes behind the DEFLATE stream are the checksum of what it
    // decodes to, most significant byte first.
    guard size - pos >= 4 else { return None }
    let expected = (data[pos].to_uint() << 24) |
      (data[pos + 1].to_uint() << 16) |
      (data[pos + 2].to_uint() << 8) |
      data[pos + 3].to_uint()
    let decoded = Bytes::from_array(output[:total])
    guard @checksum.adler32(decoded) == expected else { return None }
    break Some((decoded, pos + 4))
  }
}

///|
/// The first zlib stream of `data` and its length, or the error. A stream
/// that is complete, right and within the limit is decoded once, by
/// `pdf_flate_decode_valid`. Anything else is decoded again by the loop
/// that was the decoder before, which finds the error: damaged input costs
/// twice, and which error it is cannot differ from what it was.
fn pdf_flate_decode_prefix_limited(
  data : BytesView,
  max_output : Int32,
) -> (Bytes, Int32) raise @core.PdfError {
  guard data.length() > 0 else { return (b"", 0) }
  match pdf_flate_decode_valid(data, max_output) {
    Some(decoded) => decoded
    None => pdf_flate_decode_checked(data, max_output)
  }
}

///|
/// The loop over `@zlib.Decoder` that was all of the decoder before, kept
/// as it was: it says what a stream is that `pdf_flate_decode_valid` does
/// not answer for, which error and when. Its steps end where the zlib
/// decoder's do (a window of output is full, or the 64 KiB of input that a
/// step took are used up), the output is counted against `max_output` after
/// each, and so the order of the limit and of damage is its order.
fn pdf_flate_decode_checked(
  data : BytesView,
  max_output : Int32,
) -> (Bytes, Int32) raise @core.PdfError {
  guard data.length() > 0 else { return (b"", 0) }
  let decoder = @zlib.Decoder()
  let scratch = FixedArray::make(32768, b'\x00')
  let output = @buffer.Buffer()
  for pos = 0 {
    let status = decoder.step(data[pos:], scratch.mut_view(), end=true) catch {
      ZlibError(_, _) => raise InvalidFlateData
    }
    let produced = decoder.last_produced()
    guard produced <= max_output - output.length() else {
      raise FlateOutputLimitExceeded(max_output)
    }
    for i in 0..<produced {
      output.write_byte(scratch[i])
    }
    let accepted = pos + decoder.last_consumed()
    match status {
      Done =>
        break (output.to_bytes(), accepted - decoder.unused_input().length())
      NeedMoreInput | NeedMoreOutput => continue accepted
    }
  }
}
