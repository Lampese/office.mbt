// White-box tests of the object serialization and other internals.

///|
fn wb_latin1(b : BytesView) -> String {
  let sb = StringBuilder()
  for x in b {
    sb.write_char(x.to_int().unsafe_to_char())
  }
  sb.to_string()
}

///|
test "format_real writes the shortest digits of the f32 value like pdf-writer" {
  let cases = [
    0.0,
    1.0,
    -3.0,
    0.5,
    -0.25,
    1.0 / 3.0,
    2.0 / 3.0,
    123.456789,
    0.000004,
    0.000005,
    -0.000001,
    1.0e10,
    2147483647.0,
    -2147483648.0,
    1.0 / 0.0,
    0.0 / 0.0,
  ]
  inspect(
    cases.map(format_real).join(" "),
    content=(
      #|0 1 -3 0.5 -0.25 0.33333334 0.6666667 123.45679 0.000004 0.000005 -0.000001 10000000000.0 2147483600.0 -2147483648 0 0
    ),
  )
}

///|
test "format_real writes what pdf-writer writes" {
  let mut checked = 0
  for case in real_oracle_cases[:] {
    let (bits, expected) = case
    let got = format_real(Float::reinterpret_from_uint(bits).to_double())
    if bits == 0x4F000000U {
      // 2^31, where pdf-writer writes the saturated cast (`format_real`).
      assert_eq(expected, "2147483647")
      assert_eq(got, "2147483600.0")
    } else if got != expected {
      fail("\{bits.to_string(radix=16)}: \{got}, pdf-writer: \{expected}")
    }
    checked += 1
  }
  inspect(
    checked,
    content=(
      #|8876
    ),
  )
}

///|
test "format_real rounds an exact tie to the even digit" {
  // 142.203125, 198.203125, 242.953125, 454.890625: `f32`s exactly, and
  // halfway between two eight-digit decimals that both read back as them.
  inspect(
    [142.203125, 198.203125, 242.953125, 454.890625, 0.0078125]
    .map(format_real)
    .join(" "),
    content=(
      #|142.20312 198.20312 242.95312 454.89062 0.0078125
    ),
  )
}

///|
test "bbox_of_points" {
  debug_inspect(
    bbox_of_points([]),
    content=(
      #|None
    ),
  )
  debug_inspect(
    bbox_of_points([
      Point::from_xy(3.0, -1.0),
      Point::from_xy(-2.0, 4.0),
      Point::from_xy(1.0, 1.0),
    ]),
    content=(
      #|Some({ left: -2, top: -1, right: 3, bottom: 4 })
    ),
  )
}

///|
test "object serialization" {
  let buf = Buffer()
  write_obj(
    buf,
    Dict([
      ("Null", Null),
      ("Bool", Bool(true)),
      ("Int", Int(-7)),
      ("Real", Real(1.25)),
      ("Name", Name("A B#/(x)")),
      ("Str", Str(utf8_bytes("a(b)\\c"))),
      ("Bin", Str(b"\x00\xff")),
      ("Text", TextStr("plain")),
      ("Uni", TextStr("é")),
      ("Arr", Arr([Int(1), Ref(12)])),
    ]),
  )
  inspect(
    wb_latin1(buf.to_bytes()),
    content=(
      #|<</Null null
      #|/Bool true
      #|/Int -7
      #|/Real 1.25
      #|/Name /A#20B#23#2F#28x#29
      #|/Str (a\(b\)\\c)
      #|/Bin <00FF>
      #|/Text (plain)
      #|/Uni <FEFF00E9>
      #|/Arr [1 12 0 R]
      #|>>
    ),
  )
  let buf = Buffer()
  write_name(buf, "Ünï")
  inspect(
    wb_latin1(buf.to_bytes()),
    content=(
      #|/#C3#9Cn#C3#AF
    ),
  )
  debug_inspect(
    utf8_bytes("aé€😀"),
    content=(
      #|<Bytes: [0x61, 0xc3, 0xa9, 0xe2, 0x82, 0xac, 0xf0, 0x9f, 0x98, 0x80]>
    ),
  )
  debug_inspect(
    text_string_bytes("tab\tok"),
    content=(
      #|<Bytes: [0x74, 0x61, 0x62, 0x09, 0x6f, 0x6b]>
    ),
  )
  debug_inspect(
    text_string_bytes("€"),
    content=(
      #|<Bytes: [0xfe, 0xff, 0x20, 0xac]>
    ),
  )
  debug_inspect(
    text_string_bytes("😀"),
    content=(
      #|<Bytes: [0xfe, 0xff, 0xd8, 0x3d, 0xde, 0x00]>
    ),
  )
}

///|
test "write_file produces a parseable classic file" {
  let objects : Map[Int32, Indirect] = {
    1: Plain(Dict([("Type", Name("Catalog")), ("Pages", Ref(2))])),
    2: Plain(
      Dict([("Type", Name("Pages")), ("Count", Int(0)), ("Kids", Arr([]))]),
    ),
    4: Stream([("Foo", Int(1))], b"hello"),
  }
  let bytes = write_file("1.5", objects, 4, 1, None, None)
  let text = wb_latin1(bytes)
  inspect(
    text.has_prefix("%PDF-1.5\n%"),
    content=(
      #|true
    ),
  )
  inspect(text.contains("0000000000 65535 f\r\n0000000"), content="true")
  // pdflite's reader understands the file.
  let doc = @pdflite.pdf_read_document_from_bytes(bytes)
  inspect(doc.root, content="1")
  let stream = doc.direct(PdfIndirect(4))
  inspect(
    wb_latin1(@pdflite.pdf_decode_stream(stream).stream_bytes()),
    content="hello",
  )
}

///|
test "DictBuilder replaces entries in place" {
  let d = DictBuilder::new()
  d.set("A", Int(1))
  d.set("B", Int(2))
  d.set("A", Int(3))
  let buf = Buffer()
  write_obj(buf, d.finish())
  inspect(
    wb_latin1(buf.to_bytes()),
    content=(
      #|<</A 3
      #|/B 2
      #|>>
    ),
  )
  inspect(d.get("C") is None, content="true")
}

///|
test "format_real handles large values" {
  // (Never in exponent notation, which PDF doesn't have.)
  inspect(
    [1.5e15, -2.5e15 - 1.0, 123456789012345.6, 1.0e20, -1.5e25]
    .map(format_real)
    .join(" "),
    content=(
      #|1500000000000000 -2500000000000000 123456790000000 100000000000000000000 -15000000000000000000000000
    ),
  )
}

///|
test "validator internals" {
  let v = Validators::{ a: Some(A2_A), ua: Some(UA1), }
  inspect(v.requires_tagging(), content="true")
  inspect(v.requires_codepoint_mappings(), content="true")
  inspect(v.requires_display_doc_title(), content="true")
  inspect(v.requires_annotation_flags(), content="true")
  inspect(v.prohibits_info_dict(), content="false")
  debug_inspect(
    v.prohibits(NoDocumentTitle),
    content=(
      #|Some({ a: None, ua: Some(UA1) })
    ),
  )
  debug_inspect(
    v.prohibits(MissingTagging),
    content=(
      #|Some({ a: Some(A2_A), ua: Some(UA1) })
    ),
  )
  debug_inspect(
    v.prohibits(TooLongArray),
    content=(
      #|None
    ),
  )
  let versions : Array[PdfVersion] = [Pdf14, Pdf15, Pdf16, Pdf17, Pdf20]
  debug_inspect(
    versions.map(v => v.deprecates_cid_set()),
    content=(
      #|[false, false, false, false, true]
    ),
  )
}

///|
test "streams get exactly one Length" {
  let objects : Map[Int32, Indirect] = {
    1: Stream([("Length", Int(99)), ("Foo", Int(1))], b"abc"),
  }
  let text = wb_latin1(write_file("1.7", objects, 1, 1, None, None))
  inspect(text.contains("<</Foo 1\n/Length 3\n>>"), content="true")
}

///|
test "format_real keeps small values and never writes exponents" {
  inspect(
    [0.000001, 1.0e-7, -2.5e-9, 1.0e-40, 3.0e39, 0.1, 1.0e-6 * 3.0]
    .map(format_real)
    .join(" "),
    content=(
      #|0.000001 0.0000001 -0.0000000025 0.0000000000000000000000000000000000000001 3000000000000000000000000000000000000000 0.1 0.000003
    ),
  )
}

///|
test "write_file: the whole file, byte for byte" {
  // Object numbers of one and of two digits, numbers without an object,
  // a stream whose dictionary has a `/Length` of its own in the middle, one
  // without entries and one without data.
  let objects : Map[Int32, Indirect] = {
    1: Plain(Dict([("Type", Name("Catalog")), ("Pages", Ref(2))])),
    2: Plain(
      Dict([("Type", Name("Pages")), ("Count", Int(0)), ("Kids", Arr([]))]),
    ),
    4: Stream(
      [("A", Int(1)), ("Length", Int(99)), ("B", Name("x y"))],
      b"hello",
    ),
    5: Stream([], b"ab\ncd"),
    9: Plain(Arr([Int(-3), Real(0.5), Bool(true), Null, Str(b"s")])),
    11: Stream([("Filter", Name("FlateDecode"))], b""),
    12: Plain(Dict([("Title", TextStr("T"))])),
  }
  let bytes = write_file(
    "1.7",
    objects,
    13,
    1,
    Some(12),
    Some((b"ab", b"\x01\xff")),
  )
  // The binary marker of the header.
  assert_true(bytes[9] == b'%' && bytes[14] == b'\n')
  for i in 10..<14 {
    assert_eq(bytes[i], b'\x80')
  }
  let text = wb_latin1(bytes)
  let rest = text.unsafe_substring(start=15, end=text.length())
  inspect(
    rest.replace_all(old="\r", new="\\r"),
    content=(
      #|1 0 obj
      #|<</Type /Catalog
      #|/Pages 2 0 R
      #|>>
      #|endobj
      #|
      #|2 0 obj
      #|<</Type /Pages
      #|/Count 0
      #|/Kids []
      #|>>
      #|endobj
      #|
      #|4 0 obj
      #|<</A 1
      #|/B /x#20y
      #|/Length 5
      #|>>
      #|stream
      #|hello
      #|endstream
      #|endobj
      #|
      #|5 0 obj
      #|<</Length 5
      #|>>
      #|stream
      #|ab
      #|cd
      #|endstream
      #|endobj
      #|
      #|9 0 obj
      #|[-3 0.5 true null (s)]
      #|endobj
      #|
      #|11 0 obj
      #|<</Filter /FlateDecode
      #|/Length 0
      #|>>
      #|stream
      #|
      #|endstream
      #|endobj
      #|
      #|12 0 obj
      #|<</Title (T)
      #|>>
      #|endobj
      #|
      #|xref
      #|0 14
      #|0000000000 65535 f\r
      #|0000000015 00000 n\r
      #|0000000064 00000 n\r
      #|0000000000 65535 f\r
      #|0000000116 00000 n\r
      #|0000000185 00000 n\r
      #|0000000000 65535 f\r
      #|0000000000 65535 f\r
      #|0000000000 65535 f\r
      #|0000000239 00000 n\r
      #|0000000000 65535 f\r
      #|0000000278 00000 n\r
      #|0000000349 00000 n\r
      #|0000000000 65535 f\r
      #|trailer
      #|<</Size 14
      #|/Root 1 0 R
      #|/Info 12 0 R
      #|/ID [(ab) <01FF>]
      #|>>
      #|startxref
      #|382
      #|%%EOF
    ),
  )
  // The offsets of the table are where the objects are.
  for entry in [(1, 15), (4, 116), (9, 239), (12, 349)] {
    let (number, offset) = entry
    assert_true(
      text
      .unsafe_substring(start=offset, end=text.length())
      .has_prefix("\{number} 0 obj\n"),
    )
  }
  assert_true(
    text.unsafe_substring(start=382, end=text.length()).has_prefix("xref\n"),
  )
}
