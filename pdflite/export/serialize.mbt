// The serialization context (port of krilla's `serialize` module): object
// allocation, caching of shared resources, validation errors and the
// document-global objects that are only written when the document is
// finished.

///|
/// Settings for writing a document.
pub(all) struct SerializeSettings {
  /// Whether to pretty-print (accepted for API compatibility).
  pretty : Bool
  /// Whether to compress content streams.
  compress_content_streams : Bool
  /// Whether to avoid device color spaces: RGB and gray colors use the
  /// ICC-based sRGB and sGrey color spaces instead (forced by PDF/A). There
  /// is no CMYK profile, so CMYK colors stay in DeviceCMYK and register
  /// `ValidationError::MissingCMYKProfile`.
  no_device_cs : Bool
  /// Whether to keep the file ASCII compatible.
  ascii_compatible : Bool
  /// Whether to write XMP metadata.
  xmp_metadata : Bool
  /// The PDF version and validators.
  configuration : Configuration
  /// Whether to write a tagged document.
  enable_tagging : Bool
}

///|
pub fn SerializeSettings::default() -> SerializeSettings {
  {
    pretty: false,
    compress_content_streams: true,
    no_device_cs: false,
    ascii_compatible: false,
    xmp_metadata: true,
    configuration: Configuration::default(),
    enable_tagging: true,
  }
}

///|
pub fn SerializeSettings::pdf_version(self : SerializeSettings) -> PdfVersion {
  self.configuration.version
}

///|
pub fn SerializeSettings::validators(self : SerializeSettings) -> Validators {
  self.configuration.validators
}

///|
/// Information about a page that is known before it is serialized.
priv struct PageInfo {
  ref_ : Int32
  surface_size : Size
  mut annotations : Array[(Int32, Int32?)]
  page_label : PageLabel
}

///|
/// An element of the parent tree.
priv enum StructParentElement {
  /// The index of the page and the number of marked content IDs present on
  /// that page.
  Page(Int32, Int32)
  /// An annotation.
  Annotation(AnnotationIdentifier)
  /// A form XObject with tagged content: the stream ID and the number of
  /// marked content IDs.
  Stream(Int32, Int32)
}

///|
/// The serialization context.
priv struct SerializeContext {
  settings : SerializeSettings
  /// What the host keeps between documents.
  memo : Memo
  mut cur_ref : Int32
  objects : Map[Int32, Indirect]
  cache : Map[String, Int32]
  validation_errors : Array[(ValidationError, Validators)]
  mut location : Location?
  page_infos : Array[PageInfo]
  page_tree_ref : Int32
  font_containers : Array[FontContainer]
  named_destinations : Map[String, (Int32, XyzDestination)]
  xyz_destinations : Array[(Int32, XyzDestination)]
  pages : Array[(Int32, InternalPage)]
  struct_parents : Array[StructParentElement]
  mut outline : Outline?
  mut tag_tree : TagTree?
  embedded_files : Map[String, Int32]
  custom_heading_roles : Map[Int32, Unit]
  separation_fallbacks : Array[(SeparationColorant, RegularColor)]
  mut metadata : Metadata?
  /// The number of form XObjects with tagged content.
  mut num_tag_streams : Int32
  /// The reference of each form XObject with tagged content.
  tag_stream_refs : Map[Int32, Int32]
  /// The first error that aborts the export (raised when the document is
  /// finished, like krilla's deferred image errors).
  mut error : ExportError?
  /// The references of the ICC-based sRGB and sGrey colour spaces, once
  /// they exist.
  mut srgb_color_space : Int32?
  mut sgrey_color_space : Int32?
}

///|
fn SerializeContext::new(
  settings : SerializeSettings,
  memo : Memo,
) -> SerializeContext {
  // Override flags as required by the validators.
  let validators = settings.validators()
  let settings = {
    ..settings,
    enable_tagging: settings.enable_tagging || validators.requires_tagging(),
    xmp_metadata: settings.xmp_metadata || !validators.is_empty(),
    no_device_cs: settings.no_device_cs || validators.a is Some(_),
  }
  {
    settings,
    memo,
    cur_ref: 1,
    objects: {},
    cache: {},
    validation_errors: [],
    location: None,
    page_infos: [],
    page_tree_ref: 1,
    font_containers: [],
    named_destinations: {},
    xyz_destinations: [],
    pages: [],
    struct_parents: [],
    outline: None,
    tag_tree: None,
    embedded_files: {},
    custom_heading_roles: {},
    separation_fallbacks: [],
    metadata: None,
    num_tag_streams: 0,
    tag_stream_refs: Map([]),
    error: None,
    srgb_color_space: None,
    sgrey_color_space: None,
  }
}

///|
fn SerializeContext::new_ref(self : SerializeContext) -> Int32 {
  self.cur_ref += 1
  self.cur_ref
}

///|
fn SerializeContext::put(
  self : SerializeContext,
  ref_ : Int32,
  obj : Obj,
) -> Unit {
  self.objects[ref_] = Plain(obj)
}

///|
/// Write a stream object, compressing its data if requested. `content` says
/// that the stream is one whose compressed data the host of the document
/// may have kept ([Memo]).
fn SerializeContext::put_stream(
  self : SerializeContext,
  ref_ : Int32,
  dict : Array[(String, Obj)],
  data : Bytes,
  compress~ : Bool = true,
  content~ : Bool = false,
) -> Unit {
  if compress && data.length() > 0 {
    let encoded = if content {
      (self.memo.deflate)(data, deflate_stream_data)
    } else {
      deflate_stream_data(data)
    }
    self.put_deflated_stream(ref_, dict, encoded)
  } else {
    self.objects[ref_] = Stream(dict, data)
  }
}

///|
/// What the host of a document keeps for it between documents
/// ([Document::new_with]).
///
/// krilla keeps the results of some of its functions by their arguments
/// (`comemo::memoize`), so that a document which is written again after a
/// change, as a compiler that watches its sources does, pays for what
/// changed. This package keeps nothing between documents, no table and no
/// key. A host that writes documents again and again gives a lookup
/// instead: a function that is handed the arguments and the computation
/// and returns the result, computed now or kept from before, with its own
/// rules for what is kept and for how long.
///
/// The contract of a lookup: it returns what its computation returns for
/// the arguments it was handed. What it returns is used as it is and not
/// checked, so a document is byte for byte what it is without a [Memo] only
/// with lookups that keep to this; one that returns anything else violates
/// the contract and may corrupt the document. A lookup is called while the
/// document is finished: if it needs the result it calls the computation
/// before it returns, it does not keep the computation (which reads the
/// document), and it does not write to the document or finish it again.
/// The package does no locking and does not join two requests for the same
/// arguments: both are the host's, with its table.
///
/// `deflate` is the lookup of krilla's `deflate_encode_memoized`
/// (`stream.rs`), the filter of
/// `FilterStreamBuilder::new_from_content_stream`: the compressed data of
/// the content streams of pages, form XObjects, tiling patterns and the
/// glyphs of Type 3 fonts, of ToUnicode CMaps and of the PostScript
/// functions of gradients, where the settings ask for compressed content
/// streams. It is called with the data of the stream, which has at least
/// a byte, and with the package's compression, a function of the data
/// alone, and returns what that function returns for the data. Binary data
/// (font programs, CID sets, ICC profiles, embedded files, the samples of
/// images: krilla's `deflate_encode`) is compressed for every document, as
/// krilla does; an image can keep its compressed samples itself
/// ([Image::deflated]).
///
/// `subset` is the lookup of krilla's `subset_font` (`text/cid.rs`): the
/// subset of a font that a document embeds, with the bounding box of its
/// glyphs ([FontSubset]). It is called for every font with glyphs that are
/// embedded as outlines, with the font, with the glyph IDs of the font that
/// the document uses, in the order of their numbers in the subset
/// (`.notdef` first; what a glyph remapper holds), and with the
/// computation. The subset can have more glyphs than these, the components
/// of composite glyphs, which the subsetter adds behind them. The result is
/// a function of the font's data, its index in a collection, its variation
/// coordinates and those glyph IDs, and of nothing else of the font or the
/// document. The glyph IDs are a view of an array of the document: a host
/// that keeps them copies them. The computation raises if the font cannot
/// be subset; that error names the font of this document, so it is the
/// error to raise for this document and not one to keep for another.
pub struct Memo {
  priv deflate : (Bytes, (Bytes) -> Bytes) -> Bytes
  priv subset : (Font, ArrayView[Int32], () -> FontSubset raise ExportError) -> FontSubset raise ExportError
}

///|
/// A [Memo] of the host's lookups; what is computed for every document
/// without the one that is left out, so `Memo()` keeps nothing, which is
/// what a document uses that is given no [Memo]. (A lookup that is added
/// later is another optional parameter: calls stay what they are.)
pub fn Memo::Memo(
  deflate? : (Bytes, (Bytes) -> Bytes) -> Bytes,
  subset? : (Font, ArrayView[Int32], () -> FontSubset raise ExportError) -> FontSubset raise ExportError,
) -> Memo {
  {
    deflate: match deflate {
      Some(deflate) => deflate
      None => (data, compute) => compute(data)
    },
    subset: match subset {
      Some(subset) => subset
      None => (_, _, compute) => compute()
    },
  }
}

///|
/// The subset of a font as a document embeds it: the font file of the
/// subset, the number of its glyphs and the bounding box of their outlines
/// (what krilla's `subset_font` returns). It is made by the package and
/// kept, if at all, by the host of a document ([Memo]); nothing of it
/// changes after it is made.
pub struct FontSubset {
  priv data : Bytes
  priv num_glyphs : Int32
  priv bbox : (Float, Float, Float, Float)
}

///|
/// The number of bytes of the subset's font file: what a host that keeps
/// subsets holds per subset.
pub fn FontSubset::size(self : FontSubset) -> Int32 {
  self.data.length()
}

///|
/// The subset of a font for the glyphs of the remapper (krilla's memoized
/// `subset_font`): looked up by the host of the document, or computed
/// ([subset_font]).
fn SerializeContext::subset_font(
  self : SerializeContext,
  font : Font,
  glyph_remapper : @subsetter.GlyphRemapper,
) -> FontSubset raise ExportError {
  (self.memo.subset)(font, glyph_remapper.remapped_gids(), () => {
    let (data, num_glyphs, bbox) = subset_font(font, glyph_remapper)
    { data, num_glyphs, bbox, }
  })
}

///|
/// The compression of the data of a stream: level 6 of
/// `moonbitlang/pdflite/flate`. A function of the data alone, not of the
/// document or its settings, which is what lets an image ([Image::deflated])
/// and the host of a document ([Memo]) keep its result.
fn deflate_stream_data(data : Bytes) -> Bytes {
  @flate.pdf_flate_encode(data)
}

///|
/// Write a stream object whose data is compressed already
/// ([deflate_stream_data]).
fn SerializeContext::put_deflated_stream(
  self : SerializeContext,
  ref_ : Int32,
  dict : Array[(String, Obj)],
  encoded : Bytes,
) -> Unit {
  let dict = dict.copy()
  dict.push(("Filter", Name("FlateDecode")))
  self.objects[ref_] = Stream(dict, encoded)
}

///|
/// Write a content stream, compressed if the settings ask for it (krilla
/// `FilterStreamBuilder::new_from_content_stream`).
fn SerializeContext::put_content_stream(
  self : SerializeContext,
  ref_ : Int32,
  dict : Array[(String, Obj)],
  data : Bytes,
) -> Unit {
  self.put_stream(
    ref_,
    dict,
    data,
    compress=self.settings.compress_content_streams,
    content=true,
  )
}

///|
/// Look up or create a cached object.
fn SerializeContext::cached(
  self : SerializeContext,
  key : String,
  create : (Int32) -> Unit,
) -> Int32 {
  match self.cache.get(key) {
    Some(r) => r
    None => {
      let r = self.new_ref()
      self.cache[key] = r
      create(r)
      r
    }
  }
}

///|
fn SerializeContext::serialize_settings(
  self : SerializeContext,
) -> SerializeSettings {
  self.settings
}

///|
fn SerializeContext::register_validation_error(
  self : SerializeContext,
  error : ValidationError,
) -> Unit {
  if self.settings.validators().prohibits(error) is Some(validators) {
    self.validation_errors.push((error, validators))
  }
}

///|
/// Register an error that aborts the export (the first one is raised).
fn SerializeContext::register_error(
  self : SerializeContext,
  error : ExportError,
) -> Unit {
  if self.error is None {
    self.error = Some(error)
  }
}

///|
fn SerializeContext::set_location(
  self : SerializeContext,
  loc : Location,
) -> Unit {
  self.location = Some(loc)
}

///|
fn SerializeContext::reset_location(self : SerializeContext) -> Unit {
  self.location = None
}

///|
fn SerializeContext::validate_separation(
  self : SerializeContext,
  space : SeparationSpace,
) -> Unit {
  for entry in self.separation_fallbacks {
    if entry.0 == space.colorant {
      if entry.1 != space.fallback {
        self.register_validation_error(
          InconsistentSeparationFallback(space.colorant),
        )
      }
      return
    }
  }
  self.separation_fallbacks.push((space.colorant, space.fallback))
}

///|
/// The ICC profile stream for sRGB (`rgb`) or sGrey, matching the PDF
/// version (krilla `PdfVersion::rgb_icc`/`grey_icc`).
fn SerializeContext::icc_profile(self : SerializeContext, rgb : Bool) -> Int32 {
  let v4 = self.settings.pdf_version() >= Pdf17
  self.cached(if rgb { "icc:srgb" } else { "icc:sgrey" }, r => {
    let n = if rgb { 3 } else { 1 }
    let data = match (rgb, v4) {
      (true, true) => srgb_v4_icc
      (true, false) => srgb_v2_icc
      (false, true) => sgrey_v4_icc
      (false, false) => sgrey_v2_icc
    }
    self.put_stream(r, [("N", Int(n)), ("Range", range_obj(n))], data)
  })
}

///|
/// The ICC-based sRGB (`rgb`) or sGrey color space.
///
/// (Asked for every solid fill of a document without device colour spaces:
/// the reference is kept where it is found without a key to hash, a
/// closure and an option to make.)
fn SerializeContext::icc_color_space(
  self : SerializeContext,
  rgb : Bool,
) -> Int32? {
  let known = if rgb { self.srgb_color_space } else { self.sgrey_color_space }
  if known is Some(_) {
    return known
  }
  let r = self.cached(if rgb { "cs:srgb" } else { "cs:sgrey" }, r => {
    self.put(r, Arr([Name("ICCBased"), Ref(self.icc_profile(rgb))]))
  })
  let known = Some(r)
  if rgb {
    self.srgb_color_space = known
  } else {
    self.sgrey_color_space = known
  }
  known
}

///|
/// The color space of a regular color: `None` for device color spaces
/// (krilla `RegularColor::color_space`).
fn SerializeContext::regular_color_space(
  self : SerializeContext,
  color : RegularColor,
) -> Int32? {
  let no_device_cs = self.settings.no_device_cs
  match color {
    Rgb(_, _, _) => if no_device_cs { self.icc_color_space(true) } else { None }
    Luma(_) => if no_device_cs { self.icc_color_space(false) } else { None }
    Cmyk(_, _, _, _) => {
      if no_device_cs {
        self.register_validation_error(MissingCMYKProfile)
      }
      None
    }
  }
}

///|
/// The color space of a regular color as an object (a device color space
/// name or a reference).
fn SerializeContext::regular_color_space_obj(
  self : SerializeContext,
  color : RegularColor,
) -> Obj {
  match self.regular_color_space(color) {
    Some(r) => Ref(r)
    None =>
      Name(
        match color {
          Rgb(_, _, _) => "DeviceRGB"
          Luma(_) => "DeviceGray"
          Cmyk(_, _, _, _) => "DeviceCMYK"
        },
      )
  }
}

///|
/// Register a color space resource for a color, `None` for device color
/// spaces.
fn SerializeContext::register_colorspace(
  self : SerializeContext,
  color : Color,
) -> Int32? {
  match color {
    Regular(c) => self.regular_color_space(c)
    Separation(_, space) => {
      self.validate_separation(space)
      let key = "sep:\{Repr(space)}"
      Some(
        self.cached(key, r => {
          let name = match space.colorant {
            AllColorants => "All"
            NoColorant => "None"
            Custom(n) => n
          }
          let alt = self.regular_color_space_obj(space.fallback)
          let comps = space.fallback.to_pdf_color()
          // A type 2 (exponential) function from the tint (white for no
          // ink) to the fallback color (full ink).
          let c0 = if space.fallback is Cmyk(_, _, _, _) { 0.0 } else { 1.0 }
          let range = []
          for _ in comps {
            range.push(Real(0.0))
            range.push(Real(1.0))
          }
          let func = Dict([
            ("FunctionType", Int(2)),
            ("Domain", Arr([Int(0), Int(1)])),
            ("Range", Arr(range)),
            ("C0", Arr(comps.map(_ => Real(c0)))),
            ("C1", Arr(comps.map(c => Real(c)))),
            ("N", Int(1)),
          ])
          self.put(r, Arr([Name("Separation"), Name(name), alt, func]))
        }),
      )
    }
  }
}

///|
/// Register a page as struct parent of its marked content.
fn SerializeContext::register_page_struct_parent(
  self : SerializeContext,
  page_index : Int32,
  num_mcids : Int32,
) -> Int32? {
  if self.settings.enable_tagging {
    if num_mcids == 0 {
      return None
    }
    let id = self.struct_parents.length()
    self.struct_parents.push(Page(page_index, num_mcids))
    Some(id)
  } else {
    None
  }
}

///|
fn SerializeContext::register_annotation_parent(
  self : SerializeContext,
  ai : AnnotationIdentifier,
) -> Int32? {
  if self.settings.enable_tagging {
    let id = self.struct_parents.length()
    self.struct_parents.push(Annotation(ai))
    Some(id)
  } else {
    None
  }
}

///|
fn SerializeContext::register_xyz_destination(
  self : SerializeContext,
  dest : XyzDestination,
) -> Int32 {
  let key = "xyz:\{dest.page_index}:\{dest.point.x}:\{dest.point.y}"
  self.cached(key, r => self.xyz_destinations.push((r, dest)))
}

///|
/// Register a named destination; `None` if a different destination with
/// the same name exists.
fn SerializeContext::register_named_destination(
  self : SerializeContext,
  nd : NamedDestination,
) -> Int32? {
  match self.named_destinations.get(nd.name) {
    Some((r, existing)) => if existing == nd.xyz_dest { Some(r) } else { None }
    None => {
      let r = self.register_xyz_destination(nd.xyz_dest)
      self.named_destinations[nd.name] = (r, nd.xyz_dest)
      Some(r)
    }
  }
}

///|
fn SerializeContext::register_font_container(
  self : SerializeContext,
  font : Font,
) -> FontContainer {
  for c in self.font_containers {
    if physical_equal(c.font, font) {
      return c
    }
  }
  let c = FontContainer::new(font, self.new_ref())
  self.font_containers.push(c)
  c
}

///|
/// Register an ExtGState and return its reference.
fn SerializeContext::register_ext_g_state(
  self : SerializeContext,
  state : ExtGState,
) -> Int32 {
  let key = "gs:\{Repr(state)}"
  self.cached(key, r => {
    let d = DictBuilder::new()
    d.set("Type", Name("ExtGState"))
    if state.non_stroking_alpha is Some(a) {
      if a != 1.0 {
        self.register_validation_error(Transparency(self.location))
      }
      d.set("ca", Real(a))
    }
    if state.stroking_alpha is Some(a) {
      if a != 1.0 {
        self.register_validation_error(Transparency(self.location))
      }
      d.set("CA", Real(a))
    }
    if state.blend_mode is Some(bm) {
      if bm != "Normal" {
        self.register_validation_error(Transparency(self.location))
      }
      d.set("BM", Name(bm))
    }
    if state.mask is Some(m) {
      self.register_validation_error(Transparency(self.location))
      d.set("SMask", Ref(m))
    }
    self.put(r, d.finish())
  })
}
