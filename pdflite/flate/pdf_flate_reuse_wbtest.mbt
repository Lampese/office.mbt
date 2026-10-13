// What the adapter keeps between calls (an encoder per level, one inflater,
// one array that every call writes into first) must not show: a result is
// its own bytes, a call after a failed call is a first call, and an output
// that outgrows the shared array is what a larger array would have held.
// And the decoder of valid streams (`pdf_flate_decode_valid`) answers what
// the loop it stands in front of answers (`pdf_flate_decode_checked`),
// wherever it answers, and it answers for every valid stream.
// The bytes themselves are pinned in `pdf_flate_pins_wbtest.mbt`.

///|
test "what a call returns does not change with later calls" {
  let small = content_stream_like(3000, 31)
  let large = content_stream_like(200000, 32)
  let encoded_small = pdf_flate_encode_view(small)
  let encoded_large = pdf_flate_encode_view(large)
  // Copies in arrays of their own (a view of all of a `Bytes` is that
  // `Bytes` again when it is made owned).
  let kept_small = Bytes::makei(encoded_small.length(), i => encoded_small[i])
  let kept_large = Bytes::makei(encoded_large.length(), i => encoded_large[i])
  let decoded_small = pdf_flate_decode_view(encoded_small)
  let decoded_large = pdf_flate_decode_view(encoded_large)
  // Every later call writes into the array these were made from.
  for seed in 40..<48 {
    let other = content_stream_like(5000 + seed * 4000, seed)
    let encoded = pdf_flate_encode_view_with_level(other, seed % 10)
    assert_true(pdf_flate_decode_view(encoded) == other)
    assert_true(pdf_flate_decode_view_prefix(encoded).0 == other)
  }
  assert_true(encoded_small == kept_small)
  assert_true(encoded_large == kept_large)
  assert_true(decoded_small == small)
  assert_true(decoded_large == large)
  // A result that is exactly one window does not share it either.
  let window = incompressible(PDF_FLATE_WINDOW)
  let decoded_window = pdf_flate_decode_view(
    pdf_flate_encode_view_with_level(window, 0),
  )
  ignore(pdf_flate_decode_view(encoded_large))
  assert_true(decoded_window == window)
  assert_eq(pdf_flate_scratch.length(), PDF_FLATE_WINDOW)
}

///|
test "a call after a call that failed is a first call" {
  let input = content_stream_like(120000, 33)
  let encoded = pdf_flate_encode_view(input)
  let n = encoded.length()
  let expected = decode_verdict(encoded, 1 << 30)
  let damaged = encoded.to_fixedarray()
  damaged[n / 2] = damaged[n / 2] ^ b'\x40'
  let failures : Array[(Bytes, Int32, String)] = [
    // Damage in the middle of a stream of four windows.
    (Bytes::from_array(damaged), 1 << 30, "invalid"),
    // The input ends inside a block.
    (encoded[:n / 3].to_owned(), 1 << 30, "invalid"),
    // The limit ends the decode after its first window.
    (encoded, 40000, "limit 40000"),
    // A header that is not zlib's, before the inflater is asked at all.
    (b"\x00\x00\x03\x00\x00\x00\x00\x01", 1 << 30, "invalid"),
  ]
  for failure in failures {
    let (data, limit, verdict) = failure
    assert_eq(decode_verdict(data, limit), verdict)
    assert_eq(decode_verdict(encoded, 1 << 30), expected)
    assert_true(pdf_flate_decode_view(encoded) == input)
    // And the encoders are not the decoder's business.
    assert_true(pdf_flate_encode_view(input) == encoded)
  }
}

///|
test "the array an output outgrows is replaced, not written beyond" {
  // The encoder asks for a larger array when less than 4096 bytes of the
  // current one are free; the decoder when less than a window is. Outputs
  // of every length around those edges, each after a call that left other
  // bytes in the shared array.
  let source = incompressible(70000)
  let filler = repeating(b"\xEE", PDF_FLATE_WINDOW)
  for edge in [PDF_FLATE_WINDOW - 4096, PDF_FLATE_WINDOW, 2 * PDF_FLATE_WINDOW] {
    for delta in -3..<=3 {
      // Level 0: the input in stored blocks of five more bytes each, and
      // six bytes around them. The input ends where the output does.
      let size = edge + delta - 16
      ignore(pdf_flate_decode_view(pdf_flate_encode_view_with_level(filler, 0)))
      let stored = pdf_flate_encode_view_with_level(source[:size], 0)
      assert_true(stored.length() > size && stored.length() <= size + 31)
      assert_true(
        stored[stored.length() - 4 - 8:stored.length() - 4] ==
        source[size - 8:size],
      )
      ignore(pdf_flate_decode_view(pdf_flate_encode_view_with_level(filler, 0)))
      let (decoded, consumed) = pdf_flate_decode_view_prefix(stored)
      assert_eq(consumed, stored.length())
      assert_true(decoded[:] == source[:size])
    }
  }
  assert_eq(pdf_flate_grow(pdf_flate_scratch, 5, 40000).length(), 65536)
  assert_eq(pdf_flate_grow(pdf_flate_scratch, 5, 70000).length(), 70000)
  assert_eq(pdf_flate_scratch.length(), PDF_FLATE_WINDOW)
}

///|
/// The decoder of valid streams against the loop behind it, for one input
/// and one limit: where it answers, the loop answers the same, and where
/// the loop has a stream, it answers. Returns whether it answered.
fn valid_agrees(data : BytesView, limit : Int32) -> Bool raise {
  let checked : (Bytes, Int32)? = try
    pdf_flate_decode_checked(data, limit)
  catch {
    _ => None
  } noraise {
    stream => Some(stream)
  }
  match (pdf_flate_decode_valid(data, limit), checked) {
    (Some((decoded, consumed)), Some((expected, length))) => {
      assert_true(decoded == expected)
      assert_eq(consumed, length)
      true
    }
    (None, None) => false
    (Some(_), None) => fail("answered where the loop has an error")
    (None, Some(_)) => fail("no answer for a stream the loop decodes")
  }
}

///|
test "the decoder of valid streams answers what the loop behind it answers" {
  // Every stream of the corpus at every level, with the limit at its length
  // and one below, alone and with bytes behind it.
  for entry in pin_corpus() {
    let (_, input) = entry
    for level in 0..<=9 {
      let encoded = pdf_flate_encode_view_with_level(input, level)
      let size = input.length()
      assert_true(valid_agrees(encoded, 1 << 30))
      assert_true(valid_agrees(encoded, size))
      assert_true(!valid_agrees(encoded, size - 1))
      guard level % 3 == 0 else { continue }
      let followed = @core.pdf_bytes_concat_views([encoded, b"\nendstream"])
      assert_true(valid_agrees(followed, size))
      assert_true(valid_agrees(followed[:encoded.length() + 1], size))
      assert_true(!valid_agrees(encoded[:encoded.length() - 1], 1 << 30))
    }
  }
  // Every flipped bit and every truncation of one stream of each kind of
  // block: most are errors, a few are streams, and the two never differ.
  let mut answered = 0
  let mut refused = 0
  for entry in damage_corpus() {
    let (_, encoded) = entry
    let damaged = encoded.to_fixedarray()
    for i in 0..<encoded.length() {
      let byte = encoded[i]
      for bit in 0..<8 {
        damaged[i] = byte ^ (1 << bit).to_byte()
        if valid_agrees(Bytes::from_array(damaged), 1 << 30) {
          answered += 1
        } else {
          refused += 1
        }
      }
      damaged[i] = byte
      // (No bytes at all are not a stream: the caller answers for them.)
      if i > 0 {
        assert_true(!valid_agrees(encoded[:i], 1 << 30))
      }
    }
  }
  inspect(
    "\{answered} streams, \{refused} errors",
    content=(
      #|27 streams, 12405 errors
    ),
  )
  // Where a step of the loop ends on its input (see the pins): a byte and
  // empty blocks beyond 64 KiB, with and without damage behind them.
  let empty_blocks = repeating(b"\x00\x00\x00\xFF\xFF", 5 * 13106)
  let sparse = @core.pdf_bytes_concat_views([
    b"\x78\x01\x00\x01\x00\xFE\xFF\x41", empty_blocks, b"\x01\x00\x00\xFF\xFF\x00\x42\x00\x42",
  ])
  for limit in [0, 1, 2] {
    assert_eq(valid_agrees(sparse, limit), limit >= 1)
    assert_true(!valid_agrees(sparse[:sparse.length() - 9], limit))
  }
  // Nothing and nearly nothing.
  assert_true(pdf_flate_decode_valid(b"", 10) is None)
  assert_eq(pdf_flate_decode_prefix_limited(b"", 10), (b"", 0))
  assert_true(!valid_agrees(b"\x78", 10))
  assert_true(!valid_agrees(b"\x78\x01", 10))
}
