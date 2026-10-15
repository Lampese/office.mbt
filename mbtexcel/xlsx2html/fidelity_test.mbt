///|
test "gradient fills retain their colors and direction" {
  debug_inspect(
    @xlsx2html.style_css(
      @xlsx.Style::fill(@xlsx.Fill::gradient("FF0000", "0000FF", shading=1)),
    ),
    content="\"background-image:linear-gradient(0deg,#FF0000 0%,#0000FF 100%);\"",
  )
}

///|
test "symmetric and diagonal gradients keep their source stops" {
  debug_inspect(
    [
      @xlsx2html.style_css(
        @xlsx.Style::fill(@xlsx.Fill::gradient("112233", "445566", shading=2)),
      ),
      @xlsx2html.style_css(
        @xlsx.Style::fill(@xlsx.Fill::gradient("112233", "445566", shading=7)),
      ),
    ],
    content=(
      #|[
      #|  "background-image:linear-gradient(180deg,#112233 0%,#445566 50%,#112233 100%);",
      #|  "background-image:linear-gradient(345deg,#112233 0%,#445566 100%);",
      #|]
    ),
  )
}

///|
test "workbook colors are resolved without inventing absent theme colors" {
  let book = @xlsx.Workbook::new()
  let unknown = @xlsx.Style::font(@xlsx.Font::with_values(color_theme=10))
  let themed = @xlsx.Style::font(
    @xlsx.Font::with_values(color_theme=4, color_tint=0.5),
  )
  let invalid = @xlsx.Style::font(
    @xlsx.Font::with_values(color="112233", color_tint=2.0),
  )
  let indexed = @xlsx.Style::fill(@xlsx.Fill::solid_indexed(2))
  debug_inspect(
    (
      @xlsx2html.style_css(unknown, workbook=book),
      @xlsx2html.style_css(themed, workbook=book).contains("color:#"),
      @xlsx2html.style_css(themed),
      @xlsx2html.style_css(invalid, workbook=book),
      @xlsx2html.style_css(indexed, workbook=book),
    ),
    content="(\"\", true, \"\", \"\", \"background-color:#FF0000;\")",
  )
}

///|
test "underline and strike decorations coexist" {
  debug_inspect(
    @xlsx2html.style_css(
      @xlsx.Style::font(
        @xlsx.Font::with_values(strike=true, underline="single"),
      ),
    ),
    content="\"text-decoration:line-through underline;\"",
  )
}

///|
test "border styles retain their authored weight and line pattern" {
  debug_inspect(
    @xlsx2html.style_css(
      @xlsx.Style::border([
        @xlsx.Border::with_values("top", color="112233", style=5),
        @xlsx.Border::with_values("bottom", color="445566", style=6),
        @xlsx.Border::with_values("left", color="778899", style=3),
        @xlsx.Border::with_values("right", color="AABBCC", style=4),
      ]),
    ),
    content=(
      #|"border-top:3px solid #112233;border-bottom:3px double #445566;border-left:1px dashed #778899;border-right:1px dotted #AABBCC;"
    ),
  )
}

///|
test "malformed gradient colors cannot enter a stylesheet" {
  let css = @xlsx2html.style_css(
    @xlsx.Style::fill(
      @xlsx.Fill::gradient("</style><script>bad</script>", "0000FF"),
    ),
  )
  debug_inspect(
    (css.contains("linear-gradient("), css.contains("<")),
    content="(false, false)",
  )
}
