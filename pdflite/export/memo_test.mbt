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
