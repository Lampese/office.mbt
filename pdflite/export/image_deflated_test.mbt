// An image that keeps its compressed samples (`Image::deflated`,
// `ImageData::Deflated`): what a document is given is the image value, so
// these tests are about what could go wrong with a form that outlives a
// document. Every comparison is of whole files, byte for byte, against the
// same document drawn with `Samples`.

///|
/// Samples that compress to something, other ones for every seed.
fn test_samples(n : Int, seed : Int) -> Bytes {
  Bytes::makei(n, i => ((i / 7 * seed + i % 5 * 31 + seed) % 251).to_byte())
}

///|
fn sampled_image(
  key : String,
  seed : Int,
  width~ : Int = 40,
  height~ : Int = 30,
  alpha~ : Bool = false,
  luma~ : Bool = false,
  icc~ : Bytes? = None,
  interpolate~ : Bool = false,
) -> @export.Image {
  let n = width * height
  {
    key,
    width,
    height,
    colorspace: if luma {
      Luma
    } else {
      Rgb
    },
    data: Samples(
      test_samples(n * (if luma { 1 } else { 3 }), seed),
      if alpha {
        Some(test_samples(n, seed + 1))
      } else {
        None
      },
    ),
    icc,
    interpolate,
    inverted_cmyk: false,
  }
}

///|
/// What an export gives: the file, or the summary of its error.
fn export_outcome(f : () -> Bytes raise) -> Result[Bytes, String] {
  try f() catch {
    e => Err(export_error_summary(e))
  } noraise {
    bytes => Ok(bytes)
  }
}

///|
/// A document of one page that draws the images in their order.
fn document_of(
  images : Array[@export.Image],
  settings~ : @export.SerializeSettings = plain_settings(),
) -> Result[Bytes, String] {
  export_outcome(() => {
    one_page(
      s => {
        for i, image in images {
          s.draw_image(
            image,
            @export.Size::from_wh(10.0 + i.to_double(), 10.0).unwrap(),
          )
        }
      },
      settings~,
    )
  })
}

///|
/// The settings a kept image meets: versions, validators, with and without
/// device colour spaces and compressed content streams.
fn deflated_test_settings() -> Array[(String, @export.SerializeSettings)] {
  [
    ("plain", plain_settings()),
    ("default", @export.SerializeSettings::default()),
    (
      "content uncompressed",
      {
        ..@export.SerializeSettings::default(),
        compress_content_streams: false,
      },
    ),
    ("no device colour spaces", { ..plain_settings(), no_device_cs: true, }),
    ("ascii", { ..plain_settings(), ascii_compatible: true, }),
    ("pretty", { ..plain_settings(), pretty: true, }),
    ("1.4", settings_with(version=Pdf14)),
    ("1.5", settings_with(version=Pdf15)),
    ("1.6", settings_with(version=Pdf16)),
    ("2.0", settings_with(version=Pdf20)),
    ("A-1b", settings_with(a=Some(A1_B), version=Pdf14)),
    ("A-2b", settings_with(a=Some(A2_B))),
    ("A-3b", settings_with(a=Some(A3_B))),
    ("A-4", settings_with(a=Some(A4), version=Pdf20)),
    ("UA-1", settings_with(ua=Some(UA1))),
  ]
}

///|
test "a deflated image holds what a document would compress" {
  let image = sampled_image("a", 1, alpha=true)
  guard image.data is Samples(color, Some(alpha)) else { fail("no samples") }
  let kept = image.deflated()
  guard kept.data is Deflated(color_z, Some(alpha_z)) else {
    fail("not deflated")
  }
  assert_eq(color_z, @flate.pdf_flate_encode(color))
  assert_eq(alpha_z, @flate.pdf_flate_encode(alpha))
  assert_true(color_z.length() < color.length())
  // Nothing else of the image changes.
  assert_eq(
    (kept.key, kept.width, kept.height, kept.interpolate),
    (image.key, image.width, image.height, image.interpolate),
  )
  assert_true(kept.colorspace == image.colorspace && kept.icc == image.icc)
  // Without an alpha channel there is no second stream.
  guard sampled_image("b", 2).deflated().data is Deflated(_, None) else {
    fail("an alpha stream")
  }
  // It is done once: the kept form is returned as it is.
  assert_true(physical_equal(kept.deflated(), kept))
  // The document writes the kept streams as they are, and a reader gets the
  // samples back.
  guard document_of([kept]) is Ok(bytes) else { fail("no document") }
  let p = parse(bytes)
  let x0 = p.path(p.page(0), ["Resources", "XObject", "x0"])
  assert_eq(p.raw_stream_data(x0), color_z)
  assert_eq(p.stream_data(x0), color)
  assert_eq(p.raw_stream_data(p.get(x0, "SMask")), alpha_z)
  assert_eq(p.stream_data(p.get(x0, "SMask")), alpha)
  inspect(
    p.show(x0),
    content=(
      #|stream<</Type /XObject /Subtype /Image /Width 40 /Height 30 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask R /Filter /FlateDecode /Length 2194>>
    ),
  )
}

///|
test "a document is the same file with kept images, under every setting" {
  let icc = Bytes::makei(400, i => (i * 5).to_byte())
  let images = [
    sampled_image("rgb", 1),
    sampled_image("rgba", 2, alpha=true),
    sampled_image("luma", 3, luma=true),
    sampled_image("luma alpha", 4, luma=true, alpha=true),
    sampled_image("smooth", 5, alpha=true, interpolate=true),
    sampled_image("profile", 6, icc=Some(icc)),
    sampled_image("luma profile", 7, luma=true, alpha=true, icc=Some(icc)),
    rgb_image(key="tiny", alpha=Some(b"\x80\xff")),
  ]
  // Made once, before any document, and given to all of them.
  let kept = images.map(image => image.deflated())
  for image in kept {
    assert_true(image.data is Deflated(_))
  }
  let sets = [
    [0],
    [1],
    [2],
    [3],
    [4],
    [5],
    [6],
    [7],
    [0, 1, 2, 3, 4, 5, 6, 7],
    [7, 6, 5, 4, 3, 2, 1, 0],
  ]
  let lines = []
  for entry in deflated_test_settings() {
    let (name, settings) = entry
    let mut ok = 0
    let errors : Array[String] = []
    for set in sets {
      let plain = document_of(set.map(i => images[i]), settings~)
      let from_kept = document_of(set.map(i => kept[i]), settings~)
      assert_eq(from_kept, plain)
      match plain {
        Ok(_) => ok += 1
        Err(message) => if !errors.contains(message) { errors.push(message) }
      }
    }
    lines.push("\{name}: \{ok} files; \{errors.join(" / ")}")
  }
  // Each setting writes files, and those that refuse an image (PDF/A-1
  // has no transparency, PDF/A no interpolation) refuse it in either form.
  inspect(
    lines.join("\n"),
    content=(
      #|plain: 10 files; 
      #|default: 10 files; 
      #|content uncompressed: 10 files; 
      #|no device colour spaces: 10 files; 
      #|ascii: 10 files; 
      #|pretty: 10 files; 
      #|1.4: 10 files; 
      #|1.5: 10 files; 
      #|1.6: 10 files; 
      #|2.0: 10 files; 
      #|A-1b: 3 files; Validation: Transparency by PDF/A-1b / Validation: ImageInterpolation by PDF/A-1b; Transparency by PDF/A-1b / Validation: Transparency by PDF/A-1b; ImageInterpolation by PDF/A-1b
      #|A-2b: 7 files; Validation: ImageInterpolation by PDF/A-2b
      #|A-3b: 7 files; Validation: ImageInterpolation by PDF/A-3b
      #|A-4: 7 files; Validation: ImageInterpolation by PDF/A-4
      #|UA-1: 0 files; Validation: MissingDocumentOutline by PDF/UA-1; MissingTagging by PDF/UA-1; NoDocumentTitle by PDF/UA-1
    ),
  )
}

///|
test "kept images of equal fields and other samples stay apart" {
  // Everything a document could tell them by is equal: the key, the size,
  // the colour space. Only the samples differ.
  let one = sampled_image("same", 1, alpha=true)
  let two = sampled_image("same", 2, alpha=true)
  guard one.data is Samples(color1, Some(alpha1)) else { fail("no samples") }
  guard two.data is Samples(color2, Some(alpha2)) else { fail("no samples") }
  assert_true(color1 != color2 && alpha1 != alpha2)
  let kept1 = one.deflated()
  let kept2 = two.deflated()
  let pixels = (document : Result[Bytes, String]) => {
    guard document is Ok(bytes) else { fail("no document") }
    let p = parse(bytes)
    let x0 = p.path(p.page(0), ["Resources", "XObject", "x0"])
    (p.stream_data(x0), p.stream_data(p.get(x0, "SMask")))
  }
  // Documents one after the other, in both orders, and the first again.
  let a = document_of([kept1])
  let b = document_of([kept2])
  let c = document_of([kept1])
  assert_eq(pixels(a), (color1, alpha1))
  assert_eq(pixels(b), (color2, alpha2))
  assert_eq(a, document_of([one]))
  assert_eq(b, document_of([two]))
  assert_eq(c, a)
  assert_true(a != b)
  // Inside one document a key is one image, as it was: the first drawn.
  assert_eq(document_of([kept1, kept2]), document_of([one, two]))
  assert_eq(document_of([kept2, kept1]), document_of([two, one]))
  assert_eq(pixels(document_of([kept2, kept1])), (color2, alpha2))
}

///|
test "what a document adds to a kept image is not kept" {
  let icc = Bytes::makei(300, i => (i * 3).to_byte())
  let other_icc = Bytes::makei(300, i => (i * 3 + 1).to_byte())
  let image = sampled_image("image", 9, alpha=true)
  let kept = image.deflated()
  // The same kept image, used with `interpolate` on and off and with a
  // profile, another and none: the variants share the compressed samples.
  let variants = (base : @export.Image) => {
    [
      base,
      { ..base, interpolate: true, },
      { ..base, key: "with profile", icc: Some(icc), },
      { ..base, key: "with another", icc: Some(other_icc), },
      { ..base, key: "with profile", icc: Some(icc), interpolate: true, },
    ]
  }
  let plain = variants(image)
  let from_kept = variants(kept)
  for i in 0..<plain.length() {
    assert_eq(document_of([from_kept[i]]), document_of([plain[i]]))
  }
  assert_eq(document_of(from_kept), document_of(plain))
  guard document_of(from_kept) is Ok(bytes) else { fail("no document") }
  let p = parse(bytes)
  let xobjects = p.path(p.page(0), ["Resources", "XObject"])
  inspect(
    p.keys(xobjects).map(k => p.show(p.get(xobjects, k))).join("\n"),
    content=(
      #|stream<</Type /XObject /Subtype /Image /Width 40 /Height 30 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask R /Filter /FlateDecode /Length 2291>>
      #|stream<</Type /XObject /Subtype /Image /Width 40 /Height 30 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate true /SMask R /Filter /FlateDecode /Length 2291>>
      #|stream<</Type /XObject /Subtype /Image /Width 40 /Height 30 /ColorSpace [/ICCBased R] /BitsPerComponent 8 /SMask R /Filter /FlateDecode /Length 2291>>
      #|stream<</Type /XObject /Subtype /Image /Width 40 /Height 30 /ColorSpace [/ICCBased R] /BitsPerComponent 8 /SMask R /Filter /FlateDecode /Length 2291>>
      #|stream<</Type /XObject /Subtype /Image /Width 40 /Height 30 /ColorSpace [/ICCBased R] /BitsPerComponent 8 /Interpolate true /SMask R /Filter /FlateDecode /Length 2291>>
    ),
  )
  // A document that is refused does not change the image for the next one,
  // and the next one does not make the refusal go away.
  let smooth = { ..kept, interpolate: true, }
  let a2 = settings_with(a=Some(A2_B))
  let a1 = settings_with(a=Some(A1_B), version=Pdf14)
  let results = [
    document_of([smooth], settings=a2),
    document_of([smooth]),
    document_of([smooth], settings=a2),
    document_of([kept], settings=a1),
    document_of([kept], settings=a2),
    document_of([kept], settings=a1),
  ]
  inspect(
    results
    .map(r => {
      match r {
        Ok(_) => "ok"
        Err(message) => message
      }
    })
    .join("\n"),
    content=(
      #|Validation: ImageInterpolation by PDF/A-2b
      #|ok
      #|Validation: ImageInterpolation by PDF/A-2b
      #|Validation: Transparency by PDF/A-1b
      #|ok
      #|Validation: Transparency by PDF/A-1b
    ),
  )
  assert_eq(results[1], document_of([{ ..image, interpolate: true, }]))
  assert_eq(results[4], document_of([image], settings=a2))
}

///|
test "an image that cannot be embedded is refused by every document" {
  // There is nothing to compress in a PNG's image data, so it is what it
  // was, and each document finds the error for itself.
  let bad = png_image(1, [[1, 2, 3, 4]], Rgb, 4, 8).deflated()
  assert_true(bad.data is Png(_, _, _, _))
  let good = sampled_image("good", 3).deflated()
  let sixteen = png_image(1, [[0, 1, 0, 2, 0, 3]], Rgb, 3, 16).deflated()
  let summary = (r : Result[Bytes, String]) => {
    match r {
      Ok(_) => "ok"
      Err(message) => message
    }
  }
  let v14 = settings_with(version=Pdf14)
  let v15 = settings_with(version=Pdf15)
  inspect(
    [
      document_of([bad]),
      document_of([bad]),
      // With a kept image before and after it.
      document_of([good, bad]),
      document_of([bad, good]),
      document_of([good]),
      document_of([bad]),
      // An error of the document's version, not of the image.
      document_of([sixteen, good], settings=v14),
      document_of([sixteen, good], settings=v15),
      document_of([sixteen, good], settings=v14),
    ]
    .map(summary)
    .join("\n"),
    content=(
      #|ImageError: unsupported PNG image (4 samples of 8 bits per pixel)
      #|ImageError: unsupported PNG image (4 samples of 8 bits per pixel)
      #|ImageError: unsupported PNG image (4 samples of 8 bits per pixel)
      #|ImageError: unsupported PNG image (4 samples of 8 bits per pixel)
      #|ok
      #|ImageError: unsupported PNG image (4 samples of 8 bits per pixel)
      #|ImageError: 16 bit images are not supported in this export mode
      #|ok
      #|ImageError: 16 bit images are not supported in this export mode
    ),
  )
  // Samples that were not compressed, in the place of compressed ones, are
  // not written as a stream that no reader can decode.
  guard good.data is Deflated(good_color, None) else { fail("not deflated") }
  let raw = test_samples(40 * 30 * 3, 3)
  let not_deflated = [
    @export.Image::{ ..good, data: Deflated(raw, None), },
    { ..good, data: Deflated(b"", None), },
    { ..good, data: Deflated(good_color, Some(test_samples(40 * 30, 4))), },
    { ..good, data: Deflated(good_color, Some(b"")), },
    // A header alone, and one with a preset dictionary.
    { ..good, data: Deflated(b"\x78\x9c", None), },
    {
      ..good,
      data: Deflated(b"\x78\xbb\x00\x00\x00\x00\x03\x00\x00\x00\x00\x01", None),
    },
  ]
  inspect(
    not_deflated.map(image => summary(document_of([image]))).join("\n"),
    content=(
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
    ),
  )
  inspect(
    not_deflated.map(image => summary(document_of([image]))).join("\n"),
    content=(
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
      #|ImageError: the compressed samples of the image are not a zlib stream
    ),
  )
  assert_eq(document_of([good]), document_of([sampled_image("good", 3)]))
  // A JPEG is embedded as it is.
  let jpeg = @export.Image::{
    key: "jpeg",
    width: 3,
    height: 4,
    colorspace: Rgb,
    data: Jpeg(fake_jpeg),
    icc: None,
    interpolate: false,
    inverted_cmyk: false,
  }
  assert_true(physical_equal(jpeg.deflated(), jpeg))
  // Samples without a byte get no filter, so they are not compressed.
  let empty = @export.Image::{ ..jpeg, key: "empty", data: Samples(b"", None), }
  assert_true(empty.deflated().data is Samples(_, None))
  assert_eq(document_of([empty.deflated()]), document_of([empty]))
  let no_alpha = @export.Image::{
    ..jpeg,
    key: "no alpha",
    data: Samples(b"\x01\x02\x03", Some(b"")),
  }
  assert_true(no_alpha.deflated().data is Samples(_, Some(_)))
  assert_eq(document_of([no_alpha.deflated()]), document_of([no_alpha]))
}

///|
test "a kept image that a document draws more than once" {
  let image = sampled_image("twice", 11, alpha=true)
  let other = sampled_image("other", 12)
  let kept = image.deflated()
  let kept_other = other.deflated()
  let plain = document_of([image, other, image, image, other])
  assert_eq(document_of([kept, kept_other, kept, kept, kept_other]), plain)
  // The two forms in one document: one key, one image, whichever is first.
  assert_eq(document_of([kept, other, image, kept, kept_other]), plain)
  assert_eq(document_of([image, kept_other, kept, image, other]), plain)
  guard plain is Ok(bytes) else { fail("no document") }
  let p = parse(bytes)
  let xobjects = p.path(p.page(0), ["Resources", "XObject"])
  assert_eq(p.keys(xobjects), ["x0", "x1"])
  // On several pages of one document.
  let pages = (first : @export.Image, second : @export.Image) => {
    export_outcome(() => {
      let doc = @export.Document::new_with(plain_settings())
      for i in 0..<3 {
        let page = doc.start_page_with(
          @export.PageSettings::from_wh(100.0, 100.0).unwrap(),
        )
        let surface = page.surface()
        surface.draw_image(
          if i == 1 {
            second
          } else {
            first
          },
          @export.Size::from_wh(10.0, 10.0).unwrap(),
        )
        surface.draw_image(second, @export.Size::from_wh(20.0, 10.0).unwrap())
        surface.finish()
        page.finish()
      }
      doc.finish()
    })
  }
  assert_eq(pages(kept, kept_other), pages(image, other))
  assert_true(pages(image, other) is Ok(_))
}

///|
test "a kept image that is dropped and made again" {
  // The caller's cache is the image value. Dropping it and compressing the
  // samples again gives the same streams and the same file.
  let make = () => sampled_image("again", 21, alpha=true, interpolate=true)
  let first = document_of([make().deflated()])
  let second = document_of([make().deflated()])
  assert_eq(second, first)
  assert_eq(first, document_of([make()]))
  guard make().deflated().data is Deflated(c1, Some(a1)) else {
    fail("not deflated")
  }
  guard make().deflated().data is Deflated(c2, Some(a2)) else {
    fail("not deflated")
  }
  assert_true(c1 == c2 && a1 == a2)
  // Compressing other data in between does not change the next result (the
  // encoder is reused).
  sampled_image("between", 22, width=300, height=200).deflated() |> ignore
  guard make().deflated().data is Deflated(c3, Some(a3)) else {
    fail("not deflated")
  }
  assert_true(c1 == c3 && a1 == a3)
}

///|
/// The locations of what an export refuses: of its validation errors
/// (`Transparency`, `ImageInterpolation`) or of its image error.
fn refused_at(f : () -> Bytes raise) -> Array[UInt64?] {
  try f() catch {
    @export.Validation(errors) =>
      errors.map(e => {
        match e.0 {
          Transparency(location) | ImageInterpolation(location) => location
          _ => None
        }
      })
    @export.ImageError(location, _) => [location]
    _ => []
  } noraise {
    _ => []
  }
}

///|
test "an error of a kept image has the location of the document that draws it" {
  // The location is where the caller says an image is drawn; a kept image
  // is drawn at other places in other documents.
  let plain = sampled_image("located", 31, alpha=true, interpolate=true)
  let kept = plain.deflated()
  let bad = { ..kept, data: Deflated(b"not a stream", None), }
  let a1 = settings_with(a=Some(A1_B), version=Pdf14)
  let drawn_at = (
    image : @export.Image,
    location : UInt64?,
    settings : @export.SerializeSettings,
  ) => {
    refused_at(() => {
      one_page(
        s => {
          if location is Some(location) {
            s.set_location(location)
          }
          s.draw_image(image, @export.Size::from_wh(10.0, 10.0).unwrap())
          s.reset_location()
        },
        settings~,
      )
    })
  }
  assert_eq(drawn_at(kept, Some(1UL), a1), [Some(1UL), Some(1UL)])
  assert_eq(drawn_at(kept, Some(2UL), a1), [Some(2UL), Some(2UL)])
  assert_eq(drawn_at(kept, None, a1), [None, None])
  assert_eq(drawn_at(kept, Some(3UL), plain_settings()), [])
  assert_eq(drawn_at(kept, Some(1UL), a1), [Some(1UL), Some(1UL)])
  assert_eq(drawn_at(bad, Some(7UL), plain_settings()), [Some(7UL)])
  assert_eq(drawn_at(bad, Some(8UL), plain_settings()), [Some(8UL)])
  // As for the image with its samples.
  assert_eq(drawn_at(plain, Some(2UL), a1), [Some(2UL), Some(2UL)])
}

///|
test "kept images: CMYK samples, the smallest image, one that does not compress" {
  let icc = Bytes::makei(200, i => (i * 7).to_byte())
  let cmyk = @export.Image::{
    key: "cmyk",
    width: 1,
    height: 1,
    colorspace: Cmyk,
    data: Samples(b"\x00\x00\x00\xff", Some(b"\x80")),
    icc: None,
    interpolate: false,
    inverted_cmyk: false,
  }
  let cmyk_icc = { ..cmyk, key: "cmyk profile", icc: Some(icc), }
  let one = @export.Image::{
    ..cmyk,
    key: "one",
    colorspace: Luma,
    data: Samples(b"\x00", None),
  }
  // Samples that the compressor cannot shrink, and more of them than one
  // of its output windows holds.
  let mut seed = 0x2545F491UL
  let noise = Bytes::makei(65537, _ => {
    seed = seed ^ (seed << 13)
    seed = seed ^ (seed >> 7)
    seed = seed ^ (seed << 17)
    (seed >> 24).to_byte()
  })
  let wide = @export.Image::{
    ..one,
    key: "noise",
    width: 65537,
    data: Samples(noise, None),
  }
  let images = [cmyk, cmyk_icc, one, wide]
  let kept = images.map(image => image.deflated())
  for image in kept {
    assert_true(image.data is Deflated(_))
  }
  guard kept[3].data is Deflated(noise_z, None) else { fail("not deflated") }
  assert_true(noise_z.length() > noise.length())
  let lines = []
  for
    entry in [
      ("plain", plain_settings()),
      ("default", @export.SerializeSettings::default()),
      ("A-2b", settings_with(a=Some(A2_B))),
      ("no device colour spaces", { ..plain_settings(), no_device_cs: true, }),
    ] {
    let (name, settings) = entry
    for i, image in images {
      let plain = document_of([image], settings~)
      assert_eq(document_of([kept[i]], settings~), plain)
      let outcome = match plain {
        Ok(_) => "ok"
        Err(message) => message
      }
      lines.push("\{name}, \{image.key}: \{outcome}")
    }
    assert_eq(document_of(kept, settings~), document_of(images, settings~))
  }
  inspect(
    lines.join("\n"),
    content=(
      #|plain, cmyk: ok
      #|plain, cmyk profile: ok
      #|plain, one: ok
      #|plain, noise: ok
      #|default, cmyk: ok
      #|default, cmyk profile: ok
      #|default, one: ok
      #|default, noise: ok
      #|A-2b, cmyk: Validation: MissingCMYKProfile by PDF/A-2b
      #|A-2b, cmyk profile: ok
      #|A-2b, one: ok
      #|A-2b, noise: ok
      #|no device colour spaces, cmyk: ok
      #|no device colour spaces, cmyk profile: ok
      #|no device colour spaces, one: ok
      #|no device colour spaces, noise: ok
    ),
  )
  // A reader gets the samples back.
  guard document_of([kept[3], kept[2], kept[0]]) is Ok(bytes) else {
    fail("no document")
  }
  let p = parse(bytes)
  let xobjects = p.path(p.page(0), ["Resources", "XObject"])
  assert_eq(p.stream_data(p.get(xobjects, "x0")), noise)
  assert_eq(p.stream_data(p.get(xobjects, "x1")), b"\x00")
  assert_eq(p.stream_data(p.get(xobjects, "x2")), b"\x00\x00\x00\xff")
}

///|
test "kept images on the pages of a tagged document with metadata" {
  // The settings a caller exports with, not the plain ones of the other
  // tests: tagging, XMP metadata, compressed content streams, PDF/A.
  let image = sampled_image("first", 41, alpha=true)
  let other = sampled_image("second", 42, luma=true)
  let pages = (
    first : @export.Image,
    second : @export.Image,
    settings : @export.SerializeSettings,
  ) => {
    export_outcome(() => {
      let doc = @export.Document::new_with(settings)
      for i in 0..<4 {
        let page = doc.start_page_with(
          @export.PageSettings::from_wh(100.0, 100.0).unwrap(),
        )
        let surface = page.surface()
        surface.set_location(i.to_uint64())
        surface.draw_image(
          if i % 2 == 0 {
            first
          } else {
            second
          },
          @export.Size::from_wh(10.0, 10.0).unwrap(),
        )
        surface.draw_image(second, @export.Size::from_wh(20.0, 10.0).unwrap())
        surface.reset_location()
        surface.finish()
        page.finish()
      }
      doc.finish()
    })
  }
  let kept = image.deflated()
  let kept_other = other.deflated()
  let default = @export.SerializeSettings::default()
  let results = []
  for
    settings in [
      default,
      {
        ..default,
        configuration: { version: Pdf14, validators: { a: None, ua: None, }, },
      },
      {
        ..default,
        configuration: { version: Pdf20, validators: { a: None, ua: None, }, },
      },
      {
        ..default,
        configuration: {
          version: Pdf17,
          validators: { a: Some(A2_B), ua: None, },
        },
      },
    ] {
    let plain = pages(image, other, settings)
    assert_eq(pages(kept, kept_other, settings), plain)
    assert_eq(pages(kept, other, settings), plain)
    assert_eq(pages(image, kept_other, settings), plain)
    let outcome = match plain {
      Ok(_) => "ok"
      Err(message) => message
    }
    results.push(outcome)
  }
  inspect(
    results.join("\n"),
    content=(
      #|ok
      #|ok
      #|ok
      #|ok
    ),
  )
}
