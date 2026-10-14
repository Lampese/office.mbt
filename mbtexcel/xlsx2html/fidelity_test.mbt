///|
test "gradient fills retain their colors and direction" {
  let css = @xlsx2html.style_css(
    @xlsx.Style::fill(@xlsx.Fill::gradient("FF0000", "0000FF", shading=1)),
  )
  assert_eq(
    css, "background-image:linear-gradient(0deg,#FF0000 0%,#0000FF 100%);",
  )
}

///|
test "symmetric and diagonal gradients keep their source stops" {
  assert_eq(
    @xlsx2html.style_css(
      @xlsx.Style::fill(@xlsx.Fill::gradient("112233", "445566", shading=2)),
    ),
    "background-image:linear-gradient(180deg,#112233 0%,#445566 50%,#112233 100%);",
  )
  assert_eq(
    @xlsx2html.style_css(
      @xlsx.Style::fill(@xlsx.Fill::gradient("112233", "445566", shading=7)),
    ),
    "background-image:linear-gradient(345deg,#112233 0%,#445566 100%);",
  )
}

///|
test "workbook colors are resolved without inventing absent theme colors" {
  let book = @xlsx.Workbook::new()
  let unknown = @xlsx.Style::font(@xlsx.Font::with_values(color_theme=10))
  assert_eq(@xlsx2html.style_css(unknown, workbook=book), "")
  let themed = @xlsx.Style::font(
    @xlsx.Font::with_values(color_theme=4, color_tint=0.5),
  )
  assert_true(@xlsx2html.style_css(themed, workbook=book).contains("color:#"))
  assert_eq(@xlsx2html.style_css(themed), "")
  let invalid = @xlsx.Style::font(
    @xlsx.Font::with_values(color="112233", color_tint=2.0),
  )
  assert_eq(@xlsx2html.style_css(invalid, workbook=book), "")
  let indexed = @xlsx.Style::fill(@xlsx.Fill::solid_indexed(2))
  assert_eq(
    @xlsx2html.style_css(indexed, workbook=book),
    "background-color:#FF0000;",
  )
}

///|
test "underline and strike decorations coexist" {
  assert_eq(
    @xlsx2html.style_css(
      @xlsx.Style::font(
        @xlsx.Font::with_values(strike=true, underline="single"),
      ),
    ),
    "text-decoration:line-through underline;",
  )
}

///|
test "border styles retain their authored weight and line pattern" {
  let css = @xlsx2html.style_css(
    @xlsx.Style::border([
      @xlsx.Border::with_values("top", color="112233", style=5),
      @xlsx.Border::with_values("bottom", color="445566", style=6),
      @xlsx.Border::with_values("left", color="778899", style=3),
      @xlsx.Border::with_values("right", color="AABBCC", style=4),
    ]),
  )
  assert_true(css.contains("border-top:3px solid #112233;"))
  assert_true(css.contains("border-bottom:3px double #445566;"))
  assert_true(css.contains("border-left:1px dashed #778899;"))
  assert_true(css.contains("border-right:1px dotted #AABBCC;"))
}

///|
test "malformed gradient colors cannot enter a stylesheet" {
  let css = @xlsx2html.style_css(
    @xlsx.Style::fill(
      @xlsx.Fill::gradient("</style><script>bad</script>", "0000FF"),
    ),
  )
  assert_false(css.contains("linear-gradient("))
  assert_false(css.contains("<"))
}
