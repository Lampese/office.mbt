// White-box tests of what the text path of a content stream is written
// with: each fast form against the plain one it stands for.

///|
/// The list that the two words of `is_regular_name_byte` stand for.
fn regular_name_byte_by_list(b : Int) -> Bool {
  b > 0x20 &&
  b < 0x7F &&
  b != '#'.to_int() &&
  b != '/'.to_int() &&
  b != '('.to_int() &&
  b != ')'.to_int() &&
  b != '<'.to_int() &&
  b != '>'.to_int() &&
  b != '['.to_int() &&
  b != ']'.to_int() &&
  b != '{'.to_int() &&
  b != '}'.to_int() &&
  b != '%'.to_int()
}

///|
/// A name written character by character (`write_name` without its start
/// by code unit).
fn write_name_by_char(buf : @buffer.Buffer, name : String) -> Unit {
  buf.write_byte(b'/')
  for c in name {
    for b in utf8_bytes(c.to_string()) {
      let b = b.to_int()
      if regular_name_byte_by_list(b) {
        buf.write_byte(b.to_byte())
      } else {
        buf.write_byte(b'#')
        write_hex_byte(buf, b)
      }
    }
  }
}

///|
test "is_regular_name_byte is its list for every byte" {
  for b in -3..<400 {
    assert_eq(is_regular_name_byte(b), regular_name_byte_by_list(b))
  }
  // Code units of a string are asked too.
  for b in [0xD800, 0xDFFF, 0xFFFF, 0x10021, 0x7FFFFFFF, -0x80000000] {
    assert_false(is_regular_name_byte(b))
  }
}

///|
test "write_name escapes what is not regular wherever it is in the name" {
  let chars = [
    "a", "Z", "0", "~", "!", " ", "#", "/", "(", ")", "<", ">", "[", "]", "{", "}",
    "%", "\u{7F}", "\u{0}", "\t", "é", "€", "😀", "\u{80}", "\u{FFFF}",
  ]
  let check = (name : String) => {
    let got = Buffer()
    write_name(got, name)
    let expected = Buffer()
    write_name_by_char(expected, name)
    assert_eq(got.to_bytes(), expected.to_bytes())
  }
  check("")
  for a in chars {
    check(a)
    for b in chars {
      check(a + b)
      check("f0" + a + b)
      check(a + "Span" + b)
      check(a + b + "x")
    }
  }
  let buf = Buffer()
  write_name(buf, "f12")
  write_name(buf, "A B#")
  write_name(buf, "x😀(y)")
  inspect(
    wb_latin1(buf.to_bytes()),
    content=(
      #|/f12/A#20B#23/x#F0#9F#98#80#28y#29
    ),
  )
}

///|
test "write_string_prefix writes what write_string_bytes writes" {
  let check = (bytes : Array[Int]) => {
    let bytes = bytes.map(b => b.to_byte())
    let expected = Buffer()
    write_string_bytes(expected, Bytes::from_array(bytes))
    // The prefix of a longer array, whose rest is not looked at.
    let fixed = FixedArray::make(bytes.length() + 3, b'\x00')
    for i, b in bytes {
      fixed[i] = b
    }
    let got = Buffer()
    write_string_prefix(got, fixed, bytes.length())
    assert_eq(got.to_bytes(), expected.to_bytes())
  }
  check([])
  for b in 0..<256 {
    check([b])
    check([0x41, b])
    check([b, 0x28, 0x5C, 0x29])
    check([0x00, b, 0x7E, b])
  }
  let buf = Buffer()
  let fixed : FixedArray[Byte] = [b'a', b'(', b'\\', b')', b'\x00']
  write_string_prefix(buf, fixed, 4)
  write_string_prefix(buf, fixed, 5)
  write_string_prefix(buf, fixed, 0)
  inspect(
    wb_latin1(buf.to_bytes()),
    content=(
      #|(a\(\\\))<61285C2900>()
    ),
  )
}

///|
test "a scratch buffer grows and is cleared" {
  let scratch = Scratch::new()
  assert_eq(scratch.len, 0)
  for round in 0..<3 {
    scratch.clear()
    for i in 0..<(200 + round) {
      scratch.push((i % 251).to_byte())
    }
    assert_eq(scratch.len, 200 + round)
    for i in 0..<(200 + round) {
      assert_eq(scratch.data[i], (i % 251).to_byte())
    }
  }
  // The codes of the two kinds of fonts.
  scratch.clear()
  write_code(scratch, -1, 0x1234)
  write_code(scratch, 0, 0x1234)
  write_code(scratch, 3, 0x41)
  assert_eq(scratch.len, 4)
  assert_eq(scratch.data[0], b'\x12')
  assert_eq(scratch.data[1], b'\x34')
  assert_eq(scratch.data[2], b'\x34')
  assert_eq(scratch.data[3], b'\x41')
}

///|
fn wb_glyph(id : Int, start : Int, end : Int) -> Glyph {
  {
    glyph_id: id,
    text_start: start,
    text_end: end,
    x_advance: 0.5,
    x_offset: 0.0,
    y_advance: 0.0,
    y_offset: 0.0,
    location: None,
  }
}

///|
test "clamp_clusters copies the glyphs only if a cluster is outside the text" {
  let text = "abcd"
  let ranges = (glyphs : ArrayView[Glyph]) => {
    glyphs.map(g => (g.text_start, g.text_end))
  }
  let inside = []
  inside.push(wb_glyph(1, 0, 1))
  inside.push(wb_glyph(2, 1, 4))
  inside.push(wb_glyph(3, 4, 4))
  let clamped = clamp_clusters(inside, text)
  assert_eq(clamped.length(), 3)
  // A view of the caller's array, not a copy: it shows what is written to
  // the array afterwards.
  inside[1] = wb_glyph(7, 2, 3)
  assert_eq(clamped[1].glyph_id, 7)
  assert_eq(clamped[0].glyph_id, 1)
  let outside = []
  outside.push(wb_glyph(1, -2, 1))
  outside.push(wb_glyph(2, 1, 9))
  outside.push(wb_glyph(3, 7, 9))
  outside.push(wb_glyph(4, 3, 2))
  outside.push(wb_glyph(5, -5, -1))
  outside.push(wb_glyph(6, 2, 3))
  let clamped = clamp_clusters(outside, text)
  debug_inspect(
    ranges(clamped),
    content="[(0, 1), (1, 4), (4, 4), (3, 3), (0, 0), (2, 3)]",
  )
  // The caller's glyphs are as they were.
  debug_inspect(
    ranges(outside),
    content="[(-2, 1), (1, 9), (7, 9), (3, 2), (-5, -1), (2, 3)]",
  )
  assert_eq(clamp_clusters([], text).length(), 0)
  // One glyph outside is enough, wherever it is.
  for at in 0..<3 {
    let glyphs = []
    for i in 0..<3 {
      glyphs.push(
        if i == at {
          wb_glyph(9, 2, 5)
        } else {
          wb_glyph(i, i, i + 1)
        },
      )
    }
    let clamped = clamp_clusters(glyphs, text)
    assert_eq((clamped[at].text_start, clamped[at].text_end), (2, 4))
    assert_eq(clamped[at].glyph_id, 9)
  }
}

///|
test "is_glyph_text is the comparison with the text of the glyph" {
  let text = "aé😀b"
  let texts = [
    "", "a", "é", "aé", "😀", "é😀", "b", "😀b", "x", "aé😀b",
  ]
  for start in -2..<8 {
    for end in -2..<8 {
      let g = wb_glyph(1, start, end)
      for candidate in texts {
        assert_eq(
          is_glyph_text(candidate, text, g),
          candidate == glyph_text(text, g),
        )
        assert_eq(glyph_text_view(text, g).to_owned(), glyph_text(text, g))
      }
    }
  }
  assert_true(is_glyph_text("é", text, wb_glyph(1, 1, 2)))
  assert_false(is_glyph_text("e", text, wb_glyph(1, 1, 2)))
  assert_true(is_glyph_text("", text, wb_glyph(1, 3, 1)))
}

///|
test "write_int writes the text of Int::to_string" {
  let check = (i : Int) => {
    let buf = Buffer()
    write_int(buf, i)
    assert_eq(wb_latin1(buf.to_bytes()), i.to_string())
    let buf = Buffer()
    write_obj(buf, Int(i))
    assert_eq(wb_latin1(buf.to_bytes()), i.to_string())
    let buf = Buffer()
    write_obj(buf, Ref(i))
    assert_eq(wb_latin1(buf.to_bytes()), "\{i} 0 R")
  }
  let mut power = 1
  for _ in 0..<10 {
    for d in -2..<3 {
      check(power + d)
      check(-(power + d))
    }
    if power < 1000000000 {
      power = power * 10
    }
  }
  for i in -1100..<1100 {
    check(i)
  }
  check(2147483647)
  check(-2147483647)
  check(-2147483647 - 1)
  check(1234567890)
  check(-987654321)
}

///|
test "hex_digit is the digit of hex_digits" {
  for n in 0..<16 {
    assert_eq(hex_digit(n).to_int(), hex_digits.unsafe_get(n).to_int())
  }
  let buf = Buffer()
  write_hex_byte(buf, 0x00)
  write_hex_byte(buf, 0x09)
  write_hex_byte(buf, 0x0A)
  write_hex_byte(buf, 0x1F)
  write_hex_byte(buf, 0x9A)
  write_hex_byte(buf, 0xA9)
  write_hex_byte(buf, 0xFF)
  inspect(wb_latin1(buf.to_bytes()), content="00090A1F9AA9FF")
}
