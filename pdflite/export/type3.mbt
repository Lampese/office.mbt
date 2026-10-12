// Type 3 fonts for color glyphs (port of krilla's `text::type3`), and the
// container of all PDF fonts of an OpenType font (krilla `FontContainer`).
//
// Color glyphs (COLR, SVG, bitmap) cannot be embedded in CID fonts. They
// are drawn by a user-provided [ColorGlyphs] hook into the glyph
// procedures of Type 3 fonts (at most 256 glyphs per font).

///|
/// A hook for drawing color glyphs.
pub(all) struct ColorGlyphs {
  /// Whether the glyph must be drawn as a color glyph (krilla
  /// `!should_outline`). It must be a function of the glyph ID and do
  /// nothing else: for a glyph that is not a color glyph it is asked once
  /// per document (the answer is kept, as krilla keeps it), and it is
  /// called while a run of glyphs is drawn, when the caller's glyphs are
  /// read in place.
  is_color : (Int) -> Bool
  /// Draw the glyph in font units (y-up) onto the surface, given the
  /// context color (`0xRRGGBB`); returns whether something was drawn.
  draw : (Int, Int, Surface) -> Bool
}

///|
/// Set the color glyph hook of a font.
pub fn Font::set_color_glyphs(self : Font, hook : ColorGlyphs) -> Unit {
  self.color = Some(hook)
  // (What was kept of the answers of the hook before is dropped.)
  self.color_epoch += 1
}

///|
/// A Type 3 font.
priv struct Type3Font {
  font : Font
  /// The glyphs (glyph ID and context color) in code order.
  glyphs : Array[(Int, Int)]
  widths : Array[Double]
  cmap_entries : CmapEntries
  /// The reference of the font dictionary.
  ref_ : Int
}

///|
fn Type3Font::get_code(self : Type3Font, glyph : (Int, Int)) -> Int? {
  for i, g in self.glyphs {
    if g == glyph {
      return Some(i)
    }
  }
  None
}

///|
/// The PDF font of a glyph (`-1` for the CID font, else the index of the
/// Type 3 font) and the code of the glyph in it (krilla's
/// `(FontIdentifier, PDFGlyph)`). Not upstream: a value type, so that
/// `FontContainer::add_glyph`, which is called for every glyph of a run,
/// returns it without an allocation.
#valtype
priv struct PdfGlyph {
  fid : Int
  code : Int
}

///|
/// All PDF fonts belonging to an OpenType font.
priv struct FontContainer {
  font : Font
  cid_font : CIDFont
  /// The reference of the `Type0` font.
  ref_ : Int
  type3 : Array[Type3Font]
  /// The CID of each glyph that is known to be in the CID font, indexed by
  /// glyph ID (`-1`: not known). krilla's `cid_cache`, stored densely
  /// instead of in a hash map. As there, the color glyph hook is not asked
  /// again about a glyph that is in it; other than there, the font can be
  /// given another hook (`Font::set_color_glyphs`), and the cache is for
  /// the hook that `color_epoch` counts.
  mut cid_cache : FixedArray[Int]
  /// The `Font.color_epoch` of the hook that `cid_cache` is for.
  mut color_epoch : Int
  /// The Type 3 font and code of each colored glyph.
  type3_cache : Map[(Int, Int), (Int, Int)]
  /// The advance widths of the font's glyphs that are known, indexed by
  /// glyph ID (NaN: not known), see `FontContainer::advance_width`.
  mut advances : FixedArray[Double]
}

///|
fn FontContainer::new(font : Font, ref_ : Int) -> FontContainer {
  {
    font,
    cid_font: CIDFont::new(font),
    ref_,
    type3: [],
    cid_cache: [],
    color_epoch: font.color_epoch,
    type3_cache: {},
    advances: [],
  }
}

///|
/// Whether a glyph is drawn as an outline (in the CID font).
fn FontContainer::should_outline(self : FontContainer, glyph : Int) -> Bool {
  match self.font.color {
    Some(hook) => !(hook.is_color)(glyph)
    None => self.font.kind != NoOutlines
  }
}

///|
/// Add a glyph; returns the PDF font (`-1` for the CID font, else the
/// index of the Type 3 font) and the code of the glyph.
fn FontContainer::add_glyph(
  self : FontContainer,
  sc : SerializeContext,
  glyph : Int,
  context_color : Int,
) -> PdfGlyph {
  // We already know whether this glyph uses a CID or Type3 glyph.
  let cid_cache = self.cid_cache
  if glyph >= 0 &&
    glyph < cid_cache.length() &&
    self.color_epoch == self.font.color_epoch {
    let cid = cid_cache[glyph]
    if cid >= 0 {
      return { fid: -1, code: cid, }
    }
  }
  self.add_new_glyph(sc, glyph, context_color)
}

///|
/// `add_glyph` for a glyph that is not in the `cid_cache`.
fn FontContainer::add_new_glyph(
  self : FontContainer,
  sc : SerializeContext,
  glyph : Int,
  context_color : Int,
) -> PdfGlyph {
  if self.color_epoch != self.font.color_epoch {
    // The font was given another hook: ask it about every glyph again.
    self.cid_cache = []
    self.color_epoch = self.font.color_epoch
  }
  // (The hook first and then the codes of the color glyphs, not krilla's
  // order: a glyph that got a Type 3 code under one hook can be an outline
  // under the next.)
  if self.should_outline(glyph) {
    let cid = self.cid_font.add_glyph(glyph)
    // (Glyph IDs are `u16`s: `CIDFont::add_glyph` aborts for others.)
    if glyph >= self.cid_cache.length() {
      let grown = FixedArray::make(
        (glyph + 1).max(self.cid_cache.length() * 2).max(256),
        -1,
      )
      self.cid_cache.blit_to(grown, len=self.cid_cache.length())
      self.cid_cache = grown
    }
    self.cid_cache[glyph] = cid
    return { fid: -1, code: cid, }
  }
  let key = (glyph, context_color)
  if self.type3_cache.get(key) is Some((index, code)) {
    return { fid: index, code, }
  }
  let needs_new = match self.type3.last() {
    Some(t) => t.glyphs.length() >= 256
    None => true
  }
  if needs_new {
    self.type3.push({
      font: self.font,
      glyphs: [],
      widths: [],
      cmap_entries: CmapEntries::new(),
      ref_: sc.new_ref(),
    })
  }
  let index = self.type3.length() - 1
  let t3 = self.type3[index]
  let code = t3.glyphs.length()
  t3.glyphs.push(key)
  t3.widths.push(self.font.advance_width(glyph).unwrap_or(0.0))
  self.type3_cache[key] = (index, code)
  { fid: index, code, }
}

///|
fn FontContainer::get_codepoints(
  self : FontContainer,
  fid : Int,
  code : Int,
) -> String? {
  if fid < 0 {
    self.cid_font.get_codepoints(code)
  } else {
    match self.type3[fid].cmap_entries.get(code) {
      Some((s, _)) => Some(s)
      None => None
    }
  }
}

///|
fn FontContainer::set_codepoints(
  self : FontContainer,
  fid : Int,
  code : Int,
  text : String,
  location : Location?,
) -> Unit {
  if fid < 0 {
    self.cid_font.set_codepoints(code, text, location)
  } else {
    self.type3[fid].cmap_entries.set(code, (text, location))
  }
}

///|
/// The reference of a PDF font.
fn FontContainer::font_ref(self : FontContainer, fid : Int) -> Int {
  if fid < 0 {
    self.ref_
  } else {
    self.type3[fid].ref_
  }
}

///|
/// The units per em of a PDF font (1000 for CID fonts).
fn FontContainer::units_per_em(self : FontContainer, fid : Int) -> Double {
  if fid < 0 {
    pdf_units_per_em
  } else {
    self.font.units_per_em
  }
}

///|
/// Encode a code of a PDF font: two big-endian bytes for a CID, one for a
/// Type 3 code (krilla `PDFGlyph::encode_into`).
fn write_code(buf : Scratch, fid : Int, code : Int) -> Unit {
  if fid < 0 {
    buf.push2(((code >> 8) & 0xFF).to_byte(), (code & 0xFF).to_byte())
  } else {
    buf.push((code & 0xFF).to_byte())
  }
}

///|
/// The advance width of a glyph in font units, if `Font::advance_width`
/// gave a finite number for it; else NaN, and the font is to be asked (it
/// has no advance for the glyph, or one that is not a number).
///
/// Not upstream: krilla asks the font for every glyph it shows. Here that
/// is three allocations (the options on the way) and a walk through `hmtx`
/// and `HVAR`, so the answers are kept by glyph ID.
fn FontContainer::advance_width(self : FontContainer, glyph : Int) -> Double {
  let advances = self.advances
  if glyph >= 0 && glyph < advances.length() {
    let advance = advances[glyph]
    // (Not NaN.)
    if advance == advance {
      return advance
    }
  }
  self.new_advance_width(glyph)
}

///|
/// `advance_width` for a glyph whose advance is not kept.
fn FontContainer::new_advance_width(
  self : FontContainer,
  glyph : Int,
) -> Double {
  guard self.font.advance_width(glyph) is Some(advance) else {
    return @double.not_a_number
  }
  // (`advance - advance` is zero for a finite number and NaN otherwise.)
  guard advance - advance == 0.0 && glyph <= 0xFFFF else {
    return @double.not_a_number
  }
  if glyph >= self.advances.length() {
    let grown = FixedArray::make(
      (glyph + 1).max(self.advances.length() * 2).max(256),
      @double.not_a_number,
    )
    self.advances.blit_to(grown, len=self.advances.length())
    self.advances = grown
  }
  self.advances[glyph] = advance
  advance
}

///|
/// Serialize a Type 3 font.
fn Type3Font::serialize(self : Type3Font, sc : SerializeContext) -> Unit {
  let rd = ResourceDictionary::new()
  let font = self.font
  let mut font_bbox = Rect::{ left: 0.0, top: 0.0, right: 1.0, bottom: 1.0, }
  let char_procs = []
  for index, glyph in self.glyphs {
    let (gid, color) = glyph
    let builder = ContentBuilder::new(Transform::identity(), true)
    let surface = Surface::{
      sc,
      fill: None,
      stroke: None,
      root_builder: builder,
      sub_builders: [],
      push_instructions: [],
      mcid: None,
      kind: StreamSurface,
    }
    if font.color is Some(hook) {
      (hook.draw)(gid, color, surface) |> ignore
    }
    let stream = surface.finish_stream()
    let content = Content::new()
    content.num(self.widths[index])
    content.num(0.0)
    content.op("d0")
    if !stream.is_empty() {
      let x_object = XObject::new(stream, false, false, None)
      font_bbox = font_bbox.union(x_object.bbox())
      let r = sc.register_xobject(x_object)
      let name = rd.register(XObject, r)
      content.name(name)
      content.op("Do")
    }
    let proc_ref = sc.new_ref()
    sc.put_content_stream(proc_ref, [], content.finish())
    char_procs.push(("g\{index}", Ref(proc_ref)))
  }
  let base_font = match font.postscript_name {
    Some(n) => n
    None => "unknown"
  }
  let descriptor_ref = if sc.settings.pdf_version() >= Pdf15 {
    Some(sc.new_ref())
  } else {
    None
  }
  let cmap_ref = sc.new_ref()
  if descriptor_ref is Some(r) {
    let mut flags = 0
    if base_font.contains("Serif") {
      flags = flags | 2
    }
    if font.is_monospaced {
      flags = flags | 1
    }
    if font.italic_angle != 0.0 {
      flags = flags | 64
    }
    flags = flags | 4 | (1 << 17)
    let w = font.weight.to_int()
    let weight = if w >= 150 && w < 250 {
      200
    } else if w >= 250 && w < 350 {
      300
    } else if w >= 350 && w < 450 {
      400
    } else if w >= 450 && w < 550 {
      500
    } else if w >= 550 && w < 650 {
      600
    } else if w >= 650 && w < 750 {
      700
    } else if w >= 750 && w < 850 {
      800
    } else if w < 150 {
      100
    } else {
      900
    }
    sc.put(
      r,
      Dict([
        ("Type", Name("FontDescriptor")),
        ("FontName", Name(base_font)),
        ("Flags", Int(flags)),
        ("FontBBox", font_bbox.to_pdf()),
        ("ItalicAngle", Real(font.italic_angle)),
        ("Ascent", Real(font_bbox.bottom)),
        ("Descent", Real(font_bbox.top)),
        ("FontFamily", Str(utf8_bytes(base_font))),
        ("FontStretch", Name("Normal")),
        ("FontWeight", Int(weight)),
      ]),
    )
  }
  let d = DictBuilder::new()
  d.set("Type", Name("Font"))
  d.set("Subtype", Name("Type3"))
  d.set("Resources", rd.to_pdf())
  d.set("Name", Name(base_font))
  d.set("FontBBox", font_bbox.to_pdf())
  d.set("ToUnicode", Ref(cmap_ref))
  let s = 1.0 / font.units_per_em
  d.set("FontMatrix", Transform::from_scale(s, s).to_pdf())
  d.set("FirstChar", Int(0))
  d.set("LastChar", Int(self.glyphs.length() - 1))
  d.set("Widths", Arr(self.widths.map(w => Real(w))))
  if descriptor_ref is Some(r) {
    d.set("FontDescriptor", Ref(r))
  }
  d.set("CharProcs", Dict(char_procs))
  let differences : Array[Obj] = [Int(0)]
  for i in 0..<self.glyphs.length() {
    differences.push(Name("g\{i}"))
  }
  d.set(
    "Encoding",
    Dict([("Type", Name("Encoding")), ("Differences", Arr(differences))]),
  )
  sc.put(self.ref_, d.finish())
  let entries = []
  for g in 0..<self.glyphs.length() {
    write_cmap_entry(sc, font, self.cmap_entries.get(g), g, entries)
  }
  sc.put_content_stream(cmap_ref, [], to_unicode_cmap(entries, one_byte=true))
}
