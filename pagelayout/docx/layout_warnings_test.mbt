///|
test "nested tables and paragraph section breaks report omitted layout" {
  let bytes = docx_bytes(
    "<w:p><w:pPr><w:sectPr><w:pgSz w:w=\"16838\" w:h=\"11906\"/></w:sectPr></w:pPr><w:r><w:t>Body</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Nested</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:tc></w:tr></w:tbl>",
  )
  let document = @docx.read_docx(bytes)
  assert_true(document.unsupported.contains("nested table"))
  assert_true(document.unsupported.contains("paragraph section break"))
}

///|
test "deleted content and historical paragraph properties do not produce warnings" {
  let document = @docx.read_docx(
    docx_bytes(
      "<w:p><w:pPr><w:pPrChange><w:pPr><w:sectPr/></w:pPr></w:pPrChange></w:pPr><w:del><w:r><w:footnoteReference w:id=\"1\"/></w:r></w:del><w:r><w:t>Current text</w:t></w:r></w:p>",
    ),
  )
  assert_true(document.unsupported.is_empty())
}

///|
test "missing inline media does not claim that an image was placed" {
  let bytes = docx_with_image(
    inline_drawing().replace(old="rI", new="missingImage"),
  )
  let document = @docx.read_docx(bytes)
  assert_false(
    document.unsupported.contains("inline image placed after paragraph"),
  )
  assert_false(document.unsupported.is_empty())
}

///|
test "block controls keep visible paragraph content in the page model" {
  let document = @docx.read_docx(
    docx_bytes(
      "<w:sdt><w:sdtContent><w:p><w:r><w:t>Controlled text</w:t></w:r></w:p></w:sdtContent></w:sdt>",
    ),
  )
  let model = @paginate.paginate(document.blocks, section=document.section)
  assert_true(document.unsupported.contains("content control"))
  assert_true(
    model.pages.any(page => {
      page.items.any(item => {
        item is Text(run) && run.text.contains("Controlled text")
      })
    }),
  )
}

///|
test "ordinary paragraphs have no unsupported layout diagnostics" {
  let document = @docx.read_docx(
    docx_bytes("<w:p><w:r><w:t>Body</w:t></w:r></w:p>"),
  )
  assert_true(document.unsupported.is_empty())
}

///|
test "inline image shares the text baseline between preceding and following text" {
  let document = @docx.read_docx(
    docx_with_image("<w:t>Before</w:t>" + inline_drawing() + "<w:t>After</w:t>"),
  )
  assert_true(document.unsupported.is_empty())
  let model = @paginate.paginate(document.blocks, section=document.section)
  debug_inspect(model.validate(), content="[]")
  let text = model.pages[0].items.filter_map(item => {
    match item {
      Text(run) => Some(run)
      _ => None
    }
  })
  let images = model.pages[0].items.filter_map(item => {
    match item {
      Image(image) => Some(image)
      _ => None
    }
  })
  assert_eq(images.length(), 1)
  assert_eq(text.length(), 2)
  assert_eq(text[0].text, "Before")
  assert_eq(text[1].text, "After")
  let image = images[0]
  assert_true(image.x_pt > text[0].x_pt)
  assert_true((text[1].x_pt - image.x_pt - image.w_pt).abs() < 0.001)
  assert_true((image.y_pt + image.h_pt - text[0].baseline_pt).abs() < 0.001)
  assert_eq(text[0].baseline_pt, text[1].baseline_pt)
}

///|
test "inline picture wraps atomically and reserves vertical space for following paragraph" {
  let drawing = inline_drawing().replace(old="1828800", new="5500000")
  let bytes = docx_with_image(
    "<w:t>preceding text before a large picture </w:t>" +
    drawing +
    "<w:t> following text</w:t></w:r></w:p><w:p><w:r><w:t>Next paragraph</w:t>",
  )
  let document = @docx.read_docx(bytes)
  let model = @paginate.paginate(document.blocks, section=document.section)
  debug_inspect(model.validate(), content="[]")
  let images = model.pages[0].items.filter_map(item => {
    match item {
      Image(image) => Some(image)
      _ => None
    }
  })
  assert_eq(images.length(), 1)
  let image = images[0]
  let next = model.pages[0].items.filter_map(item => {
    match item {
      Text(run) => if run.text == "Next paragraph" { Some(run) } else { None }
      _ => None
    }
  })
  assert_eq(next.length(), 1)
  assert_true(next[0].baseline_pt > image.y_pt + image.h_pt)
  for item in model.pages[0].items {
    if item is Text(run) {
      assert_false(run.text.contains("\uFFFC"))
    }
  }
}
