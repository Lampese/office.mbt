// What must not change when the compression library under this package
// changes: the bytes the encoder writes for streams of the kinds a PDF holds
// (a PDF is byte for byte a function of them), at every level and for
// outputs of every size relative to the encoder's output window, and what
// the decoder makes of damaged input (which damage is an error, which is
// tolerated, and how many bytes of the input the first stream is).
//
// The vectors of `pdf_flate_determinism_wbtest.mbt` are aimed at the match
// finder's boundaries on small inputs at three levels; these are aimed at
// the adapter: streams of several blocks, outputs above one window, reuse of
// the encoders, and the decoder's verdicts.

///|
/// A deterministic generator (the LCG of `incompressible`).
priv struct PinRandom {
  mut state : Int32
}

///|
fn PinRandom::next(self : PinRandom, bound : Int32) -> Int32 {
  self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
  (self.state >> 16) % bound
}

///|
/// Append the characters of `text`, which are ASCII, as bytes.
fn write_ascii(out : @buffer.Buffer, text : String) -> Unit {
  for char in text {
    out.write_byte(char.to_int().to_byte())
  }
}

///|
/// `count` bytes shaped like the content stream of a page of text: text
/// objects with fonts, positions as reals, and glyph runs in hexadecimal
/// with kerning, between a few paths.
fn content_stream_like(count : Int32, seed : Int32) -> Bytes {
  let random = PinRandom::{ state: seed, }
  let out = @buffer.Buffer()
  let hex = b"0123456789ABCDEF"
  while out.length() < count {
    match random.next(8) {
      0 => {
        out.write_bytes(b"q\n")
        for _ in 0..<(1 + random.next(4)) {
          write_ascii(
            out,
            "\{random.next(600)}.\{random.next(1000)} \{random.next(800)}.\{random.next(100)} l\n",
          )
        }
        out.write_bytes(b"0.2 0.4 0.6 RG 0.75 w S\nQ\n")
      }
      _ => {
        write_ascii(
          out,
          "BT\n/F\{random.next(4)} \{8 + random.next(6)} Tf\n1 0 0 -1 \{72 + random.next(300)}.\{random.next(1000)} \{random.next(780)}.\{random.next(1000)} Tm\n[",
        )
        for _ in 0..<(1 + random.next(14)) {
          out.write_byte(b'<')
          for _ in 0..<(1 + random.next(9)) {
            // Glyph numbers of a subset: small, two bytes each.
            let glyph = random.next(180)
            out.write_byte(b'0')
            out.write_byte(b'0')
            out.write_byte(hex[glyph >> 4])
            out.write_byte(hex[glyph & 15])
          }
          out.write_byte(b'>')
          if random.next(3) == 0 {
            write_ascii(out, "\{random.next(40) - 20}.\{random.next(10)}")
          }
        }
        out.write_bytes(b"] TJ\nET\n")
      }
    }
  }
  out.to_bytes()[:count].to_owned()
}

///|
/// `count` bytes shaped like the content stream of a table: the same few
/// rows again and again with other positions, which is long matches at
/// short distances.
fn table_like(count : Int32, seed : Int32) -> Bytes {
  let random = PinRandom::{ state: seed, }
  let out = @buffer.Buffer()
  let mut y = 0
  while out.length() < count {
    y = y + 12
    write_ascii(out, "0.5 w 72 \{y} m 540 \{y} l S\n")
    for column in 0..<4 {
      write_ascii(
        out,
        "BT\n/F1 9 Tf\n1 0 0 -1 \{76 + column * 117} \{y + 9} Tm\n[<0024004C0057004B>-12<0003004F00520051\{random.next(10)}0\{random.next(10)}0>] TJ\nET\n",
      )
    }
  }
  out.to_bytes()[:count].to_owned()
}

///|
/// `rows` rows of `width` RGB samples with the filter byte of a PNG
/// predictor in front: smooth gradients with a little noise, as the samples
/// of an image are.
fn image_like(width : Int32, rows : Int32, seed : Int32) -> Bytes {
  let random = PinRandom::{ state: seed, }
  let out = @buffer.Buffer()
  for y in 0..<rows {
    out.write_byte(b'\x00')
    for x in 0..<width {
      let noise = if random.next(24) == 0 { 1 } else { 0 }
      out.write_byte(((x * 255 / width + noise) & 0xFF).to_byte())
      out.write_byte(((y * 255 / rows + noise) & 0xFF).to_byte())
      out.write_byte((((x + y) * 3 + noise) & 0xFF).to_byte())
    }
  }
  out.to_bytes()
}

///|
/// `count` bytes shaped like a font program: tables of rising 16-bit
/// offsets, runs of zeros, and stretches without structure.
fn font_like(count : Int32, seed : Int32) -> Bytes {
  let random = PinRandom::{ state: seed, }
  let out = @buffer.Buffer()
  while out.length() < count {
    match random.next(3) {
      0 => {
        let mut offset = random.next(1000)
        for _ in 0..<(64 + random.next(400)) {
          offset = offset + random.next(90)
          out.write_byte(((offset >> 8) & 0xFF).to_byte())
          out.write_byte((offset & 0xFF).to_byte())
        }
      }
      1 =>
        for _ in 0..<(8 + random.next(300)) {
          out.write_byte(b'\x00')
        }
      _ =>
        for _ in 0..<(32 + random.next(2000)) {
          out.write_byte(random.next(256).to_byte())
        }
    }
  }
  out.to_bytes()[:count].to_owned()
}

///|
/// Streams of the kinds a PDF holds, as (name, bytes). The sizes are chosen
/// against the adapter's output window of 32768 bytes: outputs far below it,
/// above one window, and above several.
fn pin_corpus() -> Array[(String, Bytes)] {
  [
    ("content 12", content_stream_like(12, 7)),
    ("content 300", content_stream_like(300, 8)),
    ("content 4 KiB", content_stream_like(4096, 9)),
    ("content 70 KiB", content_stream_like(70000, 10)),
    ("content 300 KiB", content_stream_like(300000, 11)),
    ("table 120 KiB", table_like(120000, 15)),
    ("image 96x64", image_like(96, 64, 12)),
    ("image 400x110", image_like(400, 110, 13)),
    ("font 150 KiB", font_like(150000, 14)),
    ("no structure 100 KiB", incompressible(100000)),
    ("zeros 100 KiB", repeating(b"\x00", 100000)),
  ]
}

///|
/// The bytes of every kind of stream at every level. If this fails after a
/// change of the compression library, every PDF this package writes changed
/// with it: say so in the change, with what the new bytes decode to.
test "what the encoder writes for the streams of a PDF at every level" {
  let report = StringBuilder()
  for entry in pin_corpus() {
    let (name, input) = entry
    for level in 0..<=9 {
      let encoded = pdf_flate_encode_view_with_level(input, level)
      assert_eq(pdf_flate_decode_view(encoded), input, msg="\{name} L\{level}")
      report.write_string(
        "\{name} L\{level} -> \{compressed_fingerprint(encoded)}\n",
      )
    }
  }
  inspect(
    report.to_string(),
    content=(
      #|content 12 L0 -> 23/16306037229799718848
      #|content 12 L1 -> 20/13663893613754378091
      #|content 12 L2 -> 20/13663893613754378091
      #|content 12 L3 -> 20/13663893613754378091
      #|content 12 L4 -> 20/13663893613754378091
      #|content 12 L5 -> 20/13663893613754378091
      #|content 12 L6 -> 20/13663893613754378091
      #|content 12 L7 -> 20/13663893613754378091
      #|content 12 L8 -> 20/13663893613754378091
      #|content 12 L9 -> 20/13663893613754378091
      #|content 300 L0 -> 311/10076509748087410005
      #|content 300 L1 -> 192/2798905719599662547
      #|content 300 L2 -> 192/2798905719599662547
      #|content 300 L3 -> 192/2798905719599662547
      #|content 300 L4 -> 192/6446005125071697617
      #|content 300 L5 -> 192/6446005125071697617
      #|content 300 L6 -> 192/6446005125071697617
      #|content 300 L7 -> 192/6446005125071697617
      #|content 300 L8 -> 192/6446005125071697617
      #|content 300 L9 -> 192/6446005125071697617
      #|content 4 KiB L0 -> 4107/18307322565649100353
      #|content 4 KiB L1 -> 1775/11108328261601352897
      #|content 4 KiB L2 -> 1761/3600557307230927973
      #|content 4 KiB L3 -> 1761/5213783755022461134
      #|content 4 KiB L4 -> 1722/9660629793115777999
      #|content 4 KiB L5 -> 1703/12537740963578853305
      #|content 4 KiB L6 -> 1642/15750196272227887968
      #|content 4 KiB L7 -> 1699/3271433244323570958
      #|content 4 KiB L8 -> 1699/3271433244323570958
      #|content 4 KiB L9 -> 1699/3271433244323570958
      #|content 70 KiB L0 -> 70031/11069427016531220866
      #|content 70 KiB L1 -> 27363/8640807277919862607
      #|content 70 KiB L2 -> 27001/7567876090729234039
      #|content 70 KiB L3 -> 26103/3259201900936289095
      #|content 70 KiB L4 -> 26215/12279852580423191372
      #|content 70 KiB L5 -> 25025/5074646943652972568
      #|content 70 KiB L6 -> 24571/10554048674456736999
      #|content 70 KiB L7 -> 24683/9316012433034030831
      #|content 70 KiB L8 -> 24610/14761621125877324818
      #|content 70 KiB L9 -> 24610/14761621125877324818
      #|content 300 KiB L0 -> 300101/8992636581520886230
      #|content 300 KiB L1 -> 116487/14730378569437209823
      #|content 300 KiB L2 -> 114746/10987364865353673642
      #|content 300 KiB L3 -> 109834/7523323861452850517
      #|content 300 KiB L4 -> 110959/2919486902838473965
      #|content 300 KiB L5 -> 105152/9458810833598474609
      #|content 300 KiB L6 -> 104471/16278512886393668899
      #|content 300 KiB L7 -> 103669/3769327798726476083
      #|content 300 KiB L8 -> 103414/15725569657596068816
      #|content 300 KiB L9 -> 103414/15725569657596068816
      #|table 120 KiB L0 -> 120046/12207473358740962366
      #|table 120 KiB L1 -> 10346/15459121936833900984
      #|table 120 KiB L2 -> 9902/191037919933306497
      #|table 120 KiB L3 -> 9796/9037689809534504789
      #|table 120 KiB L4 -> 9754/10862107633420498107
      #|table 120 KiB L5 -> 9631/2949461255723208683
      #|table 120 KiB L6 -> 8789/6787006379071227989
      #|table 120 KiB L7 -> 9020/7206625778120138194
      #|table 120 KiB L8 -> 9025/5316669897456350727
      #|table 120 KiB L9 -> 8992/5973496348205340919
      #|image 96x64 L0 -> 18512/4283986787066314318
      #|image 96x64 L1 -> 17324/9386558116862313172
      #|image 96x64 L2 -> 17324/9386558116862313172
      #|image 96x64 L3 -> 17324/9386558116862313172
      #|image 96x64 L4 -> 17324/9386558116862313172
      #|image 96x64 L5 -> 17324/9386558116862313172
      #|image 96x64 L6 -> 17321/12371102696718078298
      #|image 96x64 L7 -> 17324/9386558116862313172
      #|image 96x64 L8 -> 17324/9386558116862313172
      #|image 96x64 L9 -> 17324/9386558116862313172
      #|image 400x110 L0 -> 132156/9986092158624202788
      #|image 400x110 L1 -> 123389/12433945125562768838
      #|image 400x110 L2 -> 123389/12433945125562768838
      #|image 400x110 L3 -> 123389/12433945125562768838
      #|image 400x110 L4 -> 123389/12433945125562768838
      #|image 400x110 L5 -> 123389/12433945125562768838
      #|image 400x110 L6 -> 123347/3557760479655605439
      #|image 400x110 L7 -> 123389/12433945125562768838
      #|image 400x110 L8 -> 123389/12433945125562768838
      #|image 400x110 L9 -> 123389/12433945125562768838
      #|font 150 KiB L0 -> 150056/1797803068485101642
      #|font 150 KiB L1 -> 135672/12379786332185538886
      #|font 150 KiB L2 -> 135677/1762726724729344854
      #|font 150 KiB L3 -> 135675/13186502164979016534
      #|font 150 KiB L4 -> 135675/8743069433811663706
      #|font 150 KiB L5 -> 135675/13186502164979016534
      #|font 150 KiB L6 -> 135900/9485135510598367476
      #|font 150 KiB L7 -> 135604/18358978292529538443
      #|font 150 KiB L8 -> 135519/10709018981081179061
      #|font 150 KiB L9 -> 135516/8885612106621248668
      #|no structure 100 KiB L0 -> 100041/4118874355852355015
      #|no structure 100 KiB L1 -> 100041/16865789093137309397
      #|no structure 100 KiB L2 -> 100041/16865789093137309397
      #|no structure 100 KiB L3 -> 100041/16865789093137309397
      #|no structure 100 KiB L4 -> 100041/16865789093137309397
      #|no structure 100 KiB L5 -> 100041/16865789093137309397
      #|no structure 100 KiB L6 -> 100041/16865789093137309397
      #|no structure 100 KiB L7 -> 100041/16865789093137309397
      #|no structure 100 KiB L8 -> 100041/16865789093137309397
      #|no structure 100 KiB L9 -> 100041/16865789093137309397
      #|zeros 100 KiB L0 -> 100041/8809576081702676927
      #|zeros 100 KiB L1 -> 186/17856893202387021797
      #|zeros 100 KiB L2 -> 186/17856893202387021797
      #|zeros 100 KiB L3 -> 186/17856893202387021797
      #|zeros 100 KiB L4 -> 186/17856893202387021797
      #|zeros 100 KiB L5 -> 186/17856893202387021797
      #|zeros 100 KiB L6 -> 186/17856893202387021797
      #|zeros 100 KiB L7 -> 186/17856893202387021797
      #|zeros 100 KiB L8 -> 186/17856893202387021797
      #|zeros 100 KiB L9 -> 186/17856893202387021797
      #|
    ),
  )
}

///|
/// The four entry points are one encoder, and an encoder that was used
/// gives what a first use gives: whatever a call leaves behind (the cached
/// encoder of its level, an output window, a buffer) must not reach the next
/// call's output, and what a call returned must not change afterwards.
test "an encoder that was used writes what a first use writes" {
  let corpus = pin_corpus()
  // The first use of every level in this test, kept to compare with.
  let first : Array[Array[Bytes]] = []
  for entry in corpus {
    let (_, input) = entry
    first.push([
      pdf_flate_encode_view_with_level(input, 1),
      pdf_flate_encode_view(input),
      pdf_flate_encode_view_with_level(input, 9),
    ])
  }
  // Copies in arrays of their own (a view of all of a `Bytes` is that
  // `Bytes` again when it is made owned).
  let copies = first.map(fn(row) {
    row.map(fn(bytes) { Bytes::makei(bytes.length(), fn(i) { bytes[i] }) })
  })
  // Large after small, small after large, a level after another level.
  for step in 0..<(corpus.length() * 3) {
    let i = step * 7 % corpus.length()
    let (name, input) = corpus[i]
    assert_eq(
      pdf_flate_encode_with_level(input, 1),
      first[i][0],
      msg="\{name} L1",
    )
    assert_eq(pdf_flate_encode(input), first[i][1], msg="\{name} L6")
    assert_eq(
      pdf_flate_encode_view_with_level(input, 6),
      first[i][1],
      msg="\{name} L6 by level",
    )
    assert_eq(
      pdf_flate_encode_with_level(input, 9),
      first[i][2],
      msg="\{name} L9",
    )
  }
  // A view into a larger buffer is its bytes and nothing around them.
  for entry in corpus {
    let (name, input) = entry
    let surrounded = @core.pdf_bytes_concat_views([b"before", input, b"after"])
    assert_eq(
      pdf_flate_encode_view(surrounded[6:6 + input.length()]),
      pdf_flate_encode(input),
      msg=name,
    )
  }
  assert_eq(first, copies)
}

///|
/// What the decoder says of `data` with a limit on the output: the decoded
/// bytes and the length of the stream, or which error.
fn decode_verdict(data : BytesView, limit : Int32) -> String {
  try pdf_flate_decode_prefix_limited(data, limit) catch {
    InvalidFlateData => "invalid"
    FlateOutputLimitExceeded(max) => "limit \{max}"
    _ => "another error"
  } noraise {
    (decoded, consumed) => "\{compressed_fingerprint(decoded)} in \{consumed}"
  }
}

///|
/// What the decoder says of `data`, by the entry point that returns the
/// length of the stream and by the two that do not: they are one decoder,
/// whatever each does first.
fn damage_verdict(data : Bytes) -> String {
  let verdict = decode_verdict(data, 1 << 30)
  let view = try pdf_flate_decode_view(data) catch {
    InvalidFlateData => "invalid"
    _ => "another error"
  } noraise {
    decoded => compressed_fingerprint(decoded)
  }
  let owned = try pdf_flate_decode(data) catch {
    InvalidFlateData => "invalid"
    _ => "another error"
  } noraise {
    decoded => compressed_fingerprint(decoded)
  }
  if view != owned {
    "the view and the bytes differ: \{view}, \{owned}"
  } else if verdict == view || verdict.has_prefix(view + " in ") {
    verdict
  } else {
    "the entry points differ: \{verdict}, \{view}"
  }
}

///|
/// FNV-1a 64 over the characters of `text` and a line end, folded into
/// `hash`.
fn fold_verdict(hash : UInt64, text : String) -> UInt64 {
  let mut hash = hash
  for char in text {
    hash = (hash ^ char.to_int().to_uint64()) * 0x100000001B3UL
  }
  (hash ^ 0x0AUL) * 0x100000001B3UL
}

///|
/// Streams to damage, one per kind of block: stored, fixed, dynamic at the
/// default level and at the fastest.
fn damage_corpus() -> Array[(String, Bytes)] raise {
  [
    ("stored", pdf_flate_encode_view_with_level(content_stream_like(90, 21), 0)),
    ("fixed", pdf_flate_encode_view(content_stream_like(40, 22))),
    ("dynamic L6", pdf_flate_encode_view(content_stream_like(1500, 23))),
    (
      "dynamic L1",
      pdf_flate_encode_view_with_level(content_stream_like(1500, 24), 1),
    ),
  ]
}

///|
/// Every truncation, every flipped bit, every byte set to 0x00 and to 0xFF,
/// every byte left out and every byte put in twice, of one stream of each
/// kind of block. A damaged stream is an error or, where the damage is in
/// bits that carry nothing for it (the padding before a stored block or
/// after the last block, a code that no symbol uses) or behind the stream
/// (its last byte twice), the stream it was; one flipped bit of the
/// third stream gives other bytes with the same Adler-32, which zlib
/// accepts too. The table has the counts, the damaged streams that are
/// accepted, and a digest of every verdict in order.
test "what the decoder makes of every small damage to a stream" {
  let report = StringBuilder()
  for entry in damage_corpus() {
    let (name, encoded) = entry
    let length = encoded.length()
    let intact = damage_verdict(encoded)
    report.write_string("\{name}: \{length} bytes, \{intact}\n")
    let mut digest = 0xCBF29CE484222325UL
    // Truncation is always an error: no prefix of a stream is a stream.
    for size in 1..<length {
      let verdict = damage_verdict(encoded[:size].to_owned())
      assert_eq(verdict, "invalid", msg="\{name} cut at \{size}")
    }
    let damaged = encoded.to_fixedarray()
    let mut invalid = 0
    let mut accepted = 0
    let mut changed = 0
    fn note(what : String, verdict : String) {
      digest = fold_verdict(digest, verdict)
      if verdict == "invalid" {
        invalid += 1
      } else if verdict == intact {
        accepted += 1
        report.write_string("  \{what}: the stream it was\n")
      } else {
        changed += 1
        report.write_string("  \{what}: \{verdict}\n")
      }
    }
    for i in 0..<length {
      let byte = encoded[i]
      for bit in 0..<8 {
        damaged[i] = byte ^ (1 << bit).to_byte()
        note(
          "bit \{bit} of byte \{i} flipped",
          damage_verdict(Bytes::from_array(damaged)),
        )
      }
      for value in [b'\x00', b'\xFF'] {
        guard value != byte else { continue }
        damaged[i] = value
        note(
          "byte \{i} set to \{value.to_int()}",
          damage_verdict(Bytes::from_array(damaged)),
        )
      }
      damaged[i] = byte
    }
    for i in 0..<length {
      note(
        "byte \{i} left out",
        damage_verdict(
          @core.pdf_bytes_concat_views([encoded[:i], encoded[i + 1:]]),
        ),
      )
      note(
        "byte \{i} twice",
        damage_verdict(
          @core.pdf_bytes_concat_views([encoded[:i + 1], encoded[i:]]),
        ),
      )
    }
    report.write_string(
      "  \{invalid} errors, \{accepted} accepted as the stream it was, \{changed} accepted as another; digest \{digest}\n",
    )
  }
  inspect(
    report.to_string(),
    content=(
      #|stored: 101 bytes, 90/13744204159756532842 in 101
      #|  bit 3 of byte 2 flipped: the stream it was
      #|  bit 4 of byte 2 flipped: the stream it was
      #|  bit 5 of byte 2 flipped: the stream it was
      #|  bit 6 of byte 2 flipped: the stream it was
      #|  bit 7 of byte 2 flipped: the stream it was
      #|  byte 100 twice: the stream it was
      #|  1204 errors, 6 accepted as the stream it was, 0 accepted as another; digest 11285064599934443385
      #|fixed: 45 bytes, 40/14204895546518296270 in 45
      #|  bit 5 of byte 40 flipped: the stream it was
      #|  bit 6 of byte 40 flipped: the stream it was
      #|  bit 7 of byte 40 flipped: the stream it was
      #|  byte 44 twice: the stream it was
      #|  534 errors, 4 accepted as the stream it was, 0 accepted as another; digest 15332809988700697773
      #|dynamic L6: 678 bytes, 1500/6158350707046966954 in 678
      #|  bit 4 of byte 136 flipped: 1500/16185316627319690238 in 678
      #|  bit 2 of byte 673 flipped: the stream it was
      #|  bit 3 of byte 673 flipped: the stream it was
      #|  bit 4 of byte 673 flipped: the stream it was
      #|  bit 5 of byte 673 flipped: the stream it was
      #|  bit 6 of byte 673 flipped: the stream it was
      #|  bit 7 of byte 673 flipped: the stream it was
      #|  byte 677 twice: the stream it was
      #|  8123 errors, 7 accepted as the stream it was, 1 accepted as another; digest 9744864554841734162
      #|dynamic L1: 730 bytes, 1500/1162358466353306360 in 730
      #|  bit 2 of byte 118 flipped: the stream it was
      #|  bit 0 of byte 315 flipped: the stream it was
      #|  bit 1 of byte 327 flipped: the stream it was
      #|  bit 6 of byte 518 flipped: the stream it was
      #|  bit 7 of byte 573 flipped: the stream it was
      #|  bit 1 of byte 725 flipped: the stream it was
      #|  bit 2 of byte 725 flipped: the stream it was
      #|  bit 3 of byte 725 flipped: the stream it was
      #|  bit 4 of byte 725 flipped: the stream it was
      #|  bit 5 of byte 725 flipped: the stream it was
      #|  bit 6 of byte 725 flipped: the stream it was
      #|  bit 7 of byte 725 flipped: the stream it was
      #|  byte 729 twice: the stream it was
      #|  8743 errors, 13 accepted as the stream it was, 0 accepted as another; digest 907504310596300003
      #|
    ),
  )
}

///|
/// The first stream is decoded and counted whatever follows it, and wherever
/// its end falls in the decoder's input: the reader finds the end of a
/// stream whose `endstream` is damaged, and of the data of an inline image,
/// by the length this returns.
test "the length of the first stream with anything behind it" {
  // Encoded lengths around the 65536 bytes that the decoder takes of its
  // input at a time, and around twice that.
  let lengths = StringBuilder()
  for
    size in [
      65500, 65510, 65517, 65518, 65519, 65520, 65521, 65522, 65523, 65524, 65530,
      131040, 131045, 131050, 131055, 131060,
    ] {
    let input = incompressible(size)
    let encoded = pdf_flate_encode_view_with_level(input, 0)
    lengths.write_string("\{size} -> \{encoded.length()}\n")
    for
      suffix in [
        b"",
        b"\x00",
        b"\nendstream",
        repeating(b"\x78\x9c", 3),
        repeating(b"x", 65536),
        incompressible(70001),
        encoded,
      ] {
      let combined = @core.pdf_bytes_concat_views([encoded, suffix])
      let (decoded, consumed) = pdf_flate_decode_view_prefix(combined)
      assert_eq(consumed, encoded.length(), msg="\{size} + \{suffix.length()}")
      assert_true(decoded == input, msg="\{size} + \{suffix.length()}")
      assert_true(
        pdf_flate_decode_view(combined) == input,
        msg="\{size} + \{suffix.length()}",
      )
    }
  }
  inspect(
    lengths.to_string(),
    content=(
      #|65500 -> 65526
      #|65510 -> 65536
      #|65517 -> 65543
      #|65518 -> 65544
      #|65519 -> 65545
      #|65520 -> 65546
      #|65521 -> 65547
      #|65522 -> 65548
      #|65523 -> 65549
      #|65524 -> 65550
      #|65530 -> 65556
      #|131040 -> 131086
      #|131045 -> 131091
      #|131050 -> 131096
      #|131055 -> 131101
      #|131060 -> 131106
      #|
    ),
  )
  // Short streams at every offset of a buffer, with every short suffix.
  for entry in damage_corpus() {
    let (name, encoded) = entry
    let intact = pdf_flate_decode_view(encoded)
    for before in 0..<3 {
      for after in 0..<12 {
        let combined = @core.pdf_bytes_concat_views([
          repeating(b"\x78", before),
          encoded,
          repeating(b"\x01\x00\xff", after),
        ])
        let (decoded, consumed) = pdf_flate_decode_view_prefix(
          combined[before:],
        )
        assert_eq(consumed, encoded.length(), msg="\{name} \{before} \{after}")
        assert_eq(decoded, intact, msg="\{name} \{before} \{after}")
      }
    }
  }
}

///|
/// The limit on the output against damage further on in the stream. The
/// decoder works in windows of 32768 bytes of output and counts after each:
/// a stream is over the limit when a window that was decoded without an
/// error takes the output above it, so damage within the window that would
/// cross the limit is reported as damage, and damage after it as the limit.
test "the output limit and damage behind it" {
  // Stored blocks: the damage is at a known place of the output.
  let input = incompressible(100000)
  let encoded = pdf_flate_encode_view_with_level(input, 0)
  let length = encoded.length()
  let checksum = encoded.to_fixedarray()
  checksum[length - 1] = checksum[length - 1] ^ b'\x01'
  let body = encoded.to_fixedarray()
  // A byte of the last block: the output differs, the checksum fails.
  body[length - 100] = body[length - 100] ^ b'\x01'
  let repetitive = pdf_flate_encode_view(repeating(b"a", 100000))
  let streams : Array[(String, Bytes)] = [
    ("intact", encoded),
    ("cut in the middle", encoded[:length / 2].to_owned()),
    ("cut before the checksum", encoded[:length - 4].to_owned()),
    ("wrong checksum", Bytes::from_array(checksum)),
    ("a wrong byte near the end", Bytes::from_array(body)),
    ("a run, intact", repetitive),
    ("a run, cut", repetitive[:repetitive.length() - 5].to_owned()),
  ]
  let report = StringBuilder()
  for entry in streams {
    let (name, stream) = entry
    report.write_string("\{name}:\n")
    for
      limit in [
        0, 1, 32767, 32768, 32769, 49999, 50000, 65535, 65536, 65537, 98303, 98304,
        98305, 99999, 100000, 100001,
      ] {
      report.write_string("  \{limit}: \{decode_verdict(stream, limit)}\n")
    }
  }
  inspect(
    report.to_string(),
    content=(
      #|intact:
      #|  0: limit 0
      #|  1: limit 1
      #|  32767: limit 32767
      #|  32768: limit 32768
      #|  32769: limit 32769
      #|  49999: limit 49999
      #|  50000: limit 50000
      #|  65535: limit 65535
      #|  65536: limit 65536
      #|  65537: limit 65537
      #|  98303: limit 98303
      #|  98304: limit 98304
      #|  98305: limit 98305
      #|  99999: limit 99999
      #|  100000: 100000/8174481563105428762 in 100041
      #|  100001: 100000/8174481563105428762 in 100041
      #|cut in the middle:
      #|  0: limit 0
      #|  1: limit 1
      #|  32767: limit 32767
      #|  32768: invalid
      #|  32769: invalid
      #|  49999: invalid
      #|  50000: invalid
      #|  65535: invalid
      #|  65536: invalid
      #|  65537: invalid
      #|  98303: invalid
      #|  98304: invalid
      #|  98305: invalid
      #|  99999: invalid
      #|  100000: invalid
      #|  100001: invalid
      #|cut before the checksum:
      #|  0: limit 0
      #|  1: limit 1
      #|  32767: limit 32767
      #|  32768: limit 32768
      #|  32769: limit 32769
      #|  49999: limit 49999
      #|  50000: limit 50000
      #|  65535: limit 65535
      #|  65536: limit 65536
      #|  65537: limit 65537
      #|  98303: limit 98303
      #|  98304: invalid
      #|  98305: invalid
      #|  99999: invalid
      #|  100000: invalid
      #|  100001: invalid
      #|wrong checksum:
      #|  0: limit 0
      #|  1: limit 1
      #|  32767: limit 32767
      #|  32768: limit 32768
      #|  32769: limit 32769
      #|  49999: limit 49999
      #|  50000: limit 50000
      #|  65535: limit 65535
      #|  65536: limit 65536
      #|  65537: limit 65537
      #|  98303: limit 98303
      #|  98304: invalid
      #|  98305: invalid
      #|  99999: invalid
      #|  100000: invalid
      #|  100001: invalid
      #|a wrong byte near the end:
      #|  0: limit 0
      #|  1: limit 1
      #|  32767: limit 32767
      #|  32768: limit 32768
      #|  32769: limit 32769
      #|  49999: limit 49999
      #|  50000: limit 50000
      #|  65535: limit 65535
      #|  65536: limit 65536
      #|  65537: limit 65537
      #|  98303: limit 98303
      #|  98304: invalid
      #|  98305: invalid
      #|  99999: invalid
      #|  100000: invalid
      #|  100001: invalid
      #|a run, intact:
      #|  0: limit 0
      #|  1: limit 1
      #|  32767: limit 32767
      #|  32768: limit 32768
      #|  32769: limit 32769
      #|  49999: limit 49999
      #|  50000: limit 50000
      #|  65535: limit 65535
      #|  65536: limit 65536
      #|  65537: limit 65537
      #|  98303: limit 98303
      #|  98304: limit 98304
      #|  98305: limit 98305
      #|  99999: limit 99999
      #|  100000: 100000/6412025710053164037 in 187
      #|  100001: 100000/6412025710053164037 in 187
      #|a run, cut:
      #|  0: limit 0
      #|  1: limit 1
      #|  32767: limit 32767
      #|  32768: limit 32768
      #|  32769: limit 32769
      #|  49999: limit 49999
      #|  50000: limit 50000
      #|  65535: limit 65535
      #|  65536: limit 65536
      #|  65537: limit 65537
      #|  98303: limit 98303
      #|  98304: invalid
      #|  98305: invalid
      #|  99999: invalid
      #|  100000: invalid
      #|  100001: invalid
      #|
    ),
  )
}

///|
/// The same where a step of the decoder ends for another reason than a full
/// window. The zlib decoder takes its input 65536 bytes at a time, and a
/// step that uses up what it took returns with the output it has: the limit
/// is looked at there too. That shows where 64 KiB of input decode to less
/// than a window (blocks that hold nothing), and where the checksum lies
/// across the edge of what was taken, so that the last window is counted
/// before the checksum is read.
test "the output limit where a step ends on the input" {
  // One byte in a stored block, then empty stored blocks beyond the first
  // 65536 bytes of input, then the last block: empty with the checksum of
  // the byte, or of a type that does not exist.
  let empty_blocks = repeating(b"\x00\x00\x00\xFF\xFF", 5 * 13106)
  let sparse = @core.pdf_bytes_concat_views([
    b"\x78\x01\x00\x01\x00\xFE\xFF\x41", empty_blocks, b"\x01\x00\x00\xFF\xFF\x00\x42\x00\x42",
  ])
  let sparse_damaged = @core.pdf_bytes_concat_views([
    b"\x78\x01\x00\x01\x00\xFE\xFF\x41", empty_blocks, b"\x07",
  ])
  // Stored data whose stream is 65538 bytes: the checksum is the last two
  // bytes of the first 65536 and the two behind them.
  let across = pdf_flate_encode_view_with_level(incompressible(65512), 0)
  let across_wrong = across.to_fixedarray()
  across_wrong[65537] = across_wrong[65537] ^ b'\x01'
  let across_early = across.to_fixedarray()
  across_early[65534] = across_early[65534] ^ b'\x01'
  let streams : Array[(String, Bytes)] = [
    ("a byte and empty blocks", sparse),
    ("a byte and empty blocks, then damage", sparse_damaged),
    ("a checksum across the edge", across),
    ("the same, wrong behind the edge", Bytes::from_array(across_wrong)),
    ("the same, wrong before the edge", Bytes::from_array(across_early)),
    ("the same, cut at the edge", across[:65536].to_owned()),
  ]
  let report = StringBuilder()
  report.write_string("\{sparse.length()} \{across.length()}\n")
  for entry in streams {
    let (name, stream) = entry
    report.write_string("\{name}:\n")
    for limit in [0, 1, 2, 32767, 32768, 32769, 65511, 65512, 65513] {
      report.write_string("  \{limit}: \{decode_verdict(stream, limit)}\n")
    }
    report.write_string(
      "  by the other entry points: \{damage_verdict(stream)}\n",
    )
  }
  inspect(
    report.to_string(),
    content=(
      #|65547 65538
      #|a byte and empty blocks:
      #|  0: limit 0
      #|  1: 1/12638222384927744748 in 65547
      #|  2: 1/12638222384927744748 in 65547
      #|  32767: 1/12638222384927744748 in 65547
      #|  32768: 1/12638222384927744748 in 65547
      #|  32769: 1/12638222384927744748 in 65547
      #|  65511: 1/12638222384927744748 in 65547
      #|  65512: 1/12638222384927744748 in 65547
      #|  65513: 1/12638222384927744748 in 65547
      #|  by the other entry points: 1/12638222384927744748 in 65547
      #|a byte and empty blocks, then damage:
      #|  0: limit 0
      #|  1: invalid
      #|  2: invalid
      #|  32767: invalid
      #|  32768: invalid
      #|  32769: invalid
      #|  65511: invalid
      #|  65512: invalid
      #|  65513: invalid
      #|  by the other entry points: invalid
      #|a checksum across the edge:
      #|  0: limit 0
      #|  1: limit 1
      #|  2: limit 2
      #|  32767: limit 32767
      #|  32768: limit 32768
      #|  32769: limit 32769
      #|  65511: limit 65511
      #|  65512: 65512/8853881829948404452 in 65538
      #|  65513: 65512/8853881829948404452 in 65538
      #|  by the other entry points: 65512/8853881829948404452 in 65538
      #|the same, wrong behind the edge:
      #|  0: limit 0
      #|  1: limit 1
      #|  2: limit 2
      #|  32767: limit 32767
      #|  32768: invalid
      #|  32769: invalid
      #|  65511: invalid
      #|  65512: invalid
      #|  65513: invalid
      #|  by the other entry points: invalid
      #|the same, wrong before the edge:
      #|  0: limit 0
      #|  1: limit 1
      #|  2: limit 2
      #|  32767: limit 32767
      #|  32768: invalid
      #|  32769: invalid
      #|  65511: invalid
      #|  65512: invalid
      #|  65513: invalid
      #|  by the other entry points: invalid
      #|the same, cut at the edge:
      #|  0: limit 0
      #|  1: limit 1
      #|  2: limit 2
      #|  32767: limit 32767
      #|  32768: invalid
      #|  32769: invalid
      #|  65511: invalid
      #|  65512: invalid
      #|  65513: invalid
      #|  by the other entry points: invalid
      #|
    ),
  )
}

///|
/// Outputs of every length around the windows that the encoder and the
/// decoder work in (32768 bytes, and whatever part or multiple of it an
/// implementation fills or grows by): an output that ends a few bytes before
/// or after such an edge is where a drained window is lost or written twice.
/// Stored blocks give the encoder an output of a chosen length, a run gives
/// the decoder one.
test "outputs that end around the edges of a window" {
  let source = incompressible(140000)
  let run = repeating(b"ab", 140000)
  let mut digest = 0xCBF29CE484222325UL
  let mut count = 0
  for edge in [4096, 8192, 16384, 28672, 32768, 65536, 98304, 131072] {
    for delta in -9..<=9 {
      // The output of level 0 is the input, six bytes of header and
      // checksum, and five per stored block.
      for overhead in [11, 16, 21] {
        let size = edge + delta - overhead
        let stored = pdf_flate_encode_view_with_level(source[:size], 0)
        digest = fold_verdict(digest, compressed_fingerprint(stored))
        let (decoded, consumed) = pdf_flate_decode_view_prefix(stored)
        assert_true(decoded[:] == source[:size], msg="stored \{size}")
        assert_eq(consumed, stored.length(), msg="stored \{size}")
        count += 1
      }
      let size = edge + delta
      for input in [source[:size], run[:size]] {
        let encoded = pdf_flate_encode_view(input)
        digest = fold_verdict(digest, compressed_fingerprint(encoded))
        assert_true(pdf_flate_decode_view(encoded)[:] == input, msg="\{size}")
        assert_eq(
          pdf_flate_decode_prefix_limited(encoded, size).1,
          encoded.length(),
          msg="\{size}",
        )
        assert_eq(decode_verdict(encoded, size - 1), "limit \{size - 1}")
        count += 1
      }
    }
  }
  inspect(
    "\{count} outputs, digest \{digest}",
    content=(
      #|760 outputs, digest 14078209452071310031
    ),
  )
}
