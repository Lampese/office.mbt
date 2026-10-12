// What the host of a document keeps between documents (`Memo`): what it
// is asked for, that what it returns is written as it is, and that a
// document is the same bytes with a host that keeps, with one that does
// not and without one.

///|
/// What a lookup was asked for: the length of the data and how it starts.
fn data_summary(data : Bytes) -> String {
  let sb = StringBuilder()
  let n = if data.length() < 12 { data.length() } else { 12 }
  for i in 0..<n {
    let b = data[i].to_int()
    sb.write_char(if b >= 0x20 && b < 0x7f { b.unsafe_to_char() } else { '.' })
  }
  "\{data.length()} \{sb.to_string()}"
}

///|
/// A host that keeps the compressed data of every stream it is asked for:
/// what it was asked for in order (`asked`), and the number of streams
/// that were compressed for it (`computed`).
priv struct KeepingHost {
  kept : Map[Bytes, Bytes]
  asked : Array[Bytes]
  mut computed : Int32
}

///|
fn KeepingHost::new() -> KeepingHost {
  { kept: {}, asked: [], computed: 0, }
}

///|
fn KeepingHost::memo(self : KeepingHost) -> @export.Memo {
  Memo(deflate=(data, compute) => {
    self.asked.push(data)
    match self.kept.get(data) {
      Some(encoded) => encoded
      None => {
        self.computed += 1
        let encoded = compute(data)
        self.kept[data] = encoded
        encoded
      }
    }
  })
}

///|
/// Settings with compressed content streams and nothing else that adds
/// streams.
fn compressing_settings() -> @export.SerializeSettings {
  { ..plain_settings(), compress_content_streams: true, }
}

///|
/// A page with text, an image with an alpha channel and a profile, a sweep
/// gradient and a tiling pattern; `shift` moves the last shape.
fn draw_everything(s : @export.Surface, shift~ : Double = 0.0) -> Unit {
  s.draw_glyphs(
    @export.Point::from_xy(10.0, 50.0),
    [glyph(1, 0, 1), glyph(2, 1, 2)],
    test_font(),
    "AB",
    10.0,
  )
  s.draw_image(
    sampled_image("a", 1, alpha=true, icc=Some(test_samples(600, 9))),
    @export.Size::from_wh(10.0, 10.0).unwrap(),
  )
  let sweep = @export.SweepGradient::{
    cx: 5.0,
    cy: 5.0,
    start_angle: 0.0,
    end_angle: 360.0,
    transform: @export.Transform::identity(),
    spread_method: Pad,
    stops: stops2(@export.Color::rgb(255, 0, 0), @export.Color::rgb(0, 0, 255)),
    anti_alias: false,
  }
  s.set_fill(Some(fill_of(SweepGradient(sweep))))
  s.draw_path(rect_path(0.0, 0.0, 10.0, 10.0))
  let tile = s.stream_surface()
  tile.draw_path(rect_path(0.0, 0.0, 2.0, 2.0))
  let pattern = @export.Pattern::{
    stream: tile.finish_stream(),
    transform: @export.Transform::from_scale(2.0, 2.0),
    width: 4.0,
    height: 4.0,
  }
  s.set_fill(Some(fill_of(Pattern(pattern))))
  s.draw_path(rect_path(shift, 0.0, 20.0, 20.0))
}

///|
test "the host is asked for the compressed data of content streams, and of nothing else" {
  let host = KeepingHost::new()
  let bytes = one_page(
    s => draw_everything(s),
    settings=compressing_settings(),
    memo=host.memo(),
  )
  // krilla's `new_from_content_stream`: the function of the gradient, the
  // tile, the ToUnicode CMap and the page. Not the profile, the samples and
  // the alpha channel of the image, the CID set and the font program.
  inspect(
    host.asked.map(data_summary).join("\n"),
    content=(
      #|314 { 5 sub exch
      #|41 q.0 0 0 rg.0
      #|633 %!PS-Adobe-3
      #|263 q.1 0 0 -1 0
    ),
  )
  assert_eq(host.computed, 4)
  // What the lookup returned is the data of the stream, and it is the
  // package's own compression of what the lookup was given.
  let p = parse(bytes)
  let contents = p.get(p.page(0), "Contents")
  assert_eq(p.stream_data(contents), host.asked[3])
  assert_eq(p.raw_stream_data(contents), host.kept.get(host.asked[3]).unwrap())
  assert_eq(p.raw_stream_data(contents), @flate.pdf_flate_encode(host.asked[3]))
  // The file is the file of a document without a host.
  assert_eq(
    bytes,
    one_page(s => draw_everything(s), settings=compressing_settings()),
  )
}

///|
test "a document written again is not compressed again where it is what it was" {
  let host = KeepingHost::new()
  let write = (shift : Double) => {
    one_page(
      s => draw_everything(s, shift~),
      settings=compressing_settings(),
      memo=host.memo(),
    )
  }
  let plain = (shift : Double) => {
    one_page(s => draw_everything(s, shift~), settings=compressing_settings())
  }
  let first = write(0.0)
  assert_eq(host.computed, 4)
  // The same document: the host has every stream, and the file is the same
  // bytes.
  assert_eq(write(0.0), first)
  assert_eq((host.asked.length(), host.computed), (8, 4))
  // A page that changed: its stream is compressed, the others are kept.
  let edited = write(3.0)
  assert_true(edited != first)
  assert_eq((host.asked.length(), host.computed), (12, 5))
  assert_eq(edited, plain(3.0))
  // What is kept is not a document's: under other settings the host has
  // some of the streams and not others, and every file is the file of a
  // document without a host.
  for entry in deflated_test_settings() {
    let (name, settings) = entry
    let with_host = export_outcome(() => {
      one_page(s => draw_everything(s), settings~, memo=host.memo())
    })
    let without = export_outcome(() => {
      one_page(s => draw_everything(s), settings~)
    })
    assert_true(with_host == without, msg=name)
  }
}

///|
test "a lookup that breaks its contract: what it returns is written, unchecked" {
  // A deliberate violation of the contract (another compression level), to
  // pin that a result is not checked. Not a way to change the compressor:
  // a document is only what it is without a memo if the lookup returns
  // what its computation returns.
  let memo = @export.Memo(deflate=(data, _) => {
    @flate.pdf_flate_encode_with_level(data, 1) catch {
      _ => panic()
    }
  })
  let p = parse(
    one_page(s => draw_everything(s), settings=compressing_settings(), memo~),
  )
  let contents = p.get(p.page(0), "Contents")
  let data = p.stream_data(contents)
  assert_eq(
    p.raw_stream_data(contents),
    @flate.pdf_flate_encode_with_level(data, 1),
  )
  assert_true(p.raw_stream_data(contents) != @flate.pdf_flate_encode(data))
  // Binary data is not the host's: the samples of the image are compressed
  // by the package.
  let x0 = p.path(p.page(0), ["Resources", "XObject", "x0"])
  assert_eq(p.raw_stream_data(x0), @flate.pdf_flate_encode(p.stream_data(x0)))
}

///|
test "content streams that are not compressed are not looked up" {
  let host = KeepingHost::new()
  let bytes = one_page(
    s => draw_everything(s),
    settings=plain_settings(),
    memo=host.memo(),
  )
  assert_eq(host.asked.length(), 0)
  let p = parse(bytes)
  assert_false(p.has(p.get(p.page(0), "Contents"), "Filter"))
  assert_eq(bytes, one_page(s => draw_everything(s), settings=plain_settings()))
}

///|
test "data without a byte is written without a filter and looked up by nobody" {
  let host = KeepingHost::new()
  // An empty page: its content stream has no byte.
  let bytes = one_page(
    _ => (),
    settings=compressing_settings(),
    memo=host.memo(),
  )
  assert_eq(host.asked.length(), 0)
  let p = parse(bytes)
  let contents = p.get(p.page(0), "Contents")
  assert_false(p.has(contents, "Filter"))
  assert_eq(p.stream_data(contents).length(), 0)
}

///|
test "a document that is given no memo is the document of a host that keeps nothing" {
  for entry in deflated_test_settings() {
    let (name, settings) = entry
    let implicit = export_outcome(() => {
      one_page(s => draw_everything(s), settings~)
    })
    let explicit = export_outcome(() => {
      one_page(s => draw_everything(s), settings~, memo=Memo())
    })
    assert_true(implicit == explicit, msg=name)
    // Its compressed streams are level 6 of `pdflite/flate`.
    if implicit is Ok(bytes) && settings.compress_content_streams {
      let p = parse(bytes)
      let contents = p.get(p.page(0), "Contents")
      assert_eq(
        p.raw_stream_data(contents),
        @flate.pdf_flate_encode(p.stream_data(contents)),
        msg=name,
      )
    }
  }
}

///|
/// A host that keeps the subset of every font it is asked for, by the
/// glyphs alone (the tests below have one font): what it was asked for in
/// order, and the number of subsets that were computed for it.
priv struct SubsetHost {
  kept : Map[String, @export.FontSubset]
  asked : Array[(@export.Font, String)]
  mut computed : Int32
}

///|
fn SubsetHost::new() -> SubsetHost {
  { kept: {}, asked: [], computed: 0, }
}

///|
fn SubsetHost::memo(self : SubsetHost) -> @export.Memo {
  Memo(subset=(font, glyphs, compute) => {
    // (The glyphs are a view of the document's array: copied to be kept.)
    let ids = []
    for i in 0..<glyphs.length() {
      ids.push(glyphs[i].to_string())
    }
    let key = ids.join(" ")
    self.asked.push((font, key))
    match self.kept.get(key) {
      Some(subset) => subset
      None => {
        self.computed += 1
        let subset = compute()
        self.kept[key] = subset
        subset
      }
    }
  })
}

///|
/// A page of the glyphs `ids` of the font, in that order.
fn glyph_page(
  font : @export.Font,
  ids : Array[Int32],
  memo~ : @export.Memo = Memo(),
  settings~ : @export.SerializeSettings = compressing_settings(),
) -> Bytes raise {
  one_page(
    s => {
      s.draw_glyphs(
        @export.Point::from_xy(10.0, 50.0),
        ids.mapi((i, id) => glyph(id, i, i + 1)),
        font,
        "ABCDE".unsafe_substring(start=0, end=ids.length()),
        10.0,
      )
    },
    settings~,
    memo~,
  )
}

///|
test "the host is asked for the subset of a font, by the glyphs that the document uses in the order of the subset" {
  let host = SubsetHost::new()
  let font = test_font()
  let bytes = glyph_page(font, [3, 1, 3, 2], memo=host.memo())
  // `.notdef`, then the glyphs in the order of their first use.
  assert_eq(host.asked.map(a => a.1), ["0 3 1 2"])
  assert_true(physical_equal(host.asked[0].0, font))
  assert_eq(host.computed, 1)
  assert_true(host.kept.get("0 3 1 2").unwrap().size() > 0)
  // The file is the file of a document without a host.
  assert_eq(bytes, glyph_page(font, [3, 1, 3, 2]))
  // Glyph 3 is a composite glyph of glyph 1: alone, it is asked for alone
  // (the subsetter adds its component), and that is another subset than
  // the one of both.
  let alone = glyph_page(font, [3], memo=host.memo())
  let both = glyph_page(font, [3, 1], memo=host.memo())
  assert_eq(host.asked.map(a => a.1), ["0 3 1 2", "0 3", "0 3 1"])
  assert_eq(host.computed, 3)
  assert_eq(alone, glyph_page(font, [3]))
  assert_eq(both, glyph_page(font, [3, 1]))
}

///|
test "a font that is embedded again with the same glyphs is not subset again" {
  let host = SubsetHost::new()
  let font = test_font()
  let first = glyph_page(font, [1, 2], memo=host.memo())
  assert_eq(first, glyph_page(font, [1, 2], memo=host.memo()))
  assert_eq((host.asked.length(), host.computed), (2, 1))
  // The same glyphs in another order, and other glyphs, are other subsets.
  let swapped = glyph_page(font, [2, 1], memo=host.memo())
  let more = glyph_page(font, [1, 2, 3], memo=host.memo())
  assert_eq(host.asked.map(a => a.1), ["0 1 2", "0 1 2", "0 2 1", "0 1 2 3"])
  assert_eq(host.computed, 3)
  assert_eq(swapped, glyph_page(font, [2, 1]))
  assert_eq(more, glyph_page(font, [1, 2, 3]))
  // What is kept is not a document's: every file under other settings is
  // the file of a document without a host, with the subset that was kept.
  for entry in deflated_test_settings() {
    let (name, settings) = entry
    let with_host = export_outcome(() => {
      glyph_page(font, [1, 2], memo=host.memo(), settings~)
    })
    let without = export_outcome(() => glyph_page(font, [1, 2], settings~))
    assert_true(with_host == without, msg=name)
  }
  assert_eq(host.computed, 3)
  // Another font object of the same data is the same font to this host.
  assert_eq(glyph_page(test_font(), [1, 2], memo=host.memo()), first)
  assert_eq(host.computed, 3)
}

///|
test "a font that cannot be subset raises through the lookup" {
  // A loca entry pointing before the glyf table makes the subsetter fail.
  let data = test_font_data()
  let loca = table_record(data, "loca")
  let loca_at = (data[loca + 8].to_int() << 24) |
    (data[loca + 9].to_int() << 16) |
    (data[loca + 10].to_int() << 8) |
    data[loca + 11].to_int()
  let font = @export.Font::new(
    patch(data, loca_at + 4, [0xFF, 0xFF, 0xFF, 0xF0]),
    0,
  ).unwrap()
  let host = SubsetHost::new()
  for _ in 0..<2 {
    inspect(
      export_result(() => glyph_page(font, [1, 2], memo=host.memo())),
      content="FontError: failed to subset font: malformed font",
    )
  }
  // The host kept nothing, and was asked both times.
  assert_eq((host.asked.length(), host.computed, host.kept.length()), (2, 2, 0))
}

///|
test "a document without text asks for no subset" {
  let host = SubsetHost::new()
  one_page(s => s.draw_path(rect_path(0.0, 0.0, 10.0, 10.0)), memo=host.memo())
  |> ignore
  assert_eq(host.asked.length(), 0)
}
