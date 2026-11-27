#import "@preview/nulite:0.2.0" as nulite
#import "brand.typ": colors, fonts, series

// nulite hands the chart to JavaScript, which only takes JSON's types: decimals become
// floats, dates become ISO 8601 strings, and fields that are none are left out
#let plain(value) = {
  if type(value) == dictionary {
    value.pairs().filter(((_, field)) => field != none).map(((key, field)) => (key, plain(field))).to-dict()
  } else if type(value) == array {
    value.map(plain)
  } else if type(value) == decimal {
    float(value)
  } else if type(value) == datetime {
    value.display("[year]-[month]-[day]")
  } else {
    value
  }
}

#let hex(color) = color.to-hex()

// The look every chart shares: the document's font, recessive axes and hairline gridlines
#let config = (
  font: fonts.serif,
  view: (stroke: "transparent"),
  axis: (
    labelColor: hex(colors.muted),
    labelFontSize: 9,
    titleColor: hex(colors.muted),
    titleFontSize: 9,
    titleFontWeight: "normal",
    gridColor: "#e6eaee",
    domainColor: hex(colors.rule),
    tickColor: hex(colors.rule),
  ),
  axisX: (grid: false, labelAngle: 0, title: ""),
  axisY: (domain: false, ticks: false, title: ""),
  legend: (orient: "top", title: "", labelColor: hex(colors.ink), labelFontSize: 9, symbolStrokeWidth: 2),
)

// Axis labels as compact numbers, such as $250K and $1.2M, after a prefix such as "$"
#let compact(prefix) = {
  let prefix = "'" + prefix + "' + "
  (
    "datum.value >= 1e6 ? "
      + prefix
      + "format(datum.value / 1e6, '.1~f') + 'M' : "
      + "datum.value >= 1e3 ? "
      + prefix
      + "format(datum.value / 1e3, ',~f') + 'K' : "
      + prefix
      + "format(datum.value, ',')"
  )
}

#let chart(spec, width, height) = nulite.render(width: width, height: height, plain(spec + (config: config)))

// Columns, one for each value, in the order they're given: monthly revenue, say. The y axis
// is labelled with compact numbers, after `prefix`
#let column-chart(values, x: "x", y: "y", prefix: "", width: 100%, height: 5.5cm) = chart(
  (
    data: (values: values),
    mark: (type: "bar", cornerRadiusEnd: 3, width: (band: 0.55), color: hex(series.at(0))),
    encoding: (
      x: (field: x, type: "ordinal", sort: values.map(value => value.at(x))),
      y: (field: y, type: "quantitative", axis: (labelExpr: compact(prefix), tickCount: 5)),
    ),
  ),
  width,
  height,
)

// A line for each series, labelled at its end. `values` has a row for each point: its x,
// its y, and the name of its series. Series get the brand's colors in the order of `names`
#let line-chart(values, x: "x", y: "y", series-field: "series", names: (), prefix: "", width: 100%, height: 6cm) = {
  let last = values.last().at(x)
  let encoding = (
    x: (field: x, type: "ordinal", sort: values.map(value => value.at(x)).dedup()),
    y: (field: y, type: "quantitative", axis: (labelExpr: compact(prefix), tickCount: 5)),
    color: (field: series-field, type: "nominal", scale: (domain: names, range: series.slice(0, names.len()).map(hex))),
  )
  chart(
    (
      data: (values: values),
      encoding: encoding,
      layer: (
        (mark: (type: "line", strokeWidth: 2, interpolate: "monotone")),
        (mark: (type: "point", filled: true, size: 28, opacity: 1)),
        (
          transform: ((filter: (field: x, equal: last)),),
          mark: (type: "text", align: "left", dx: 8, fontSize: 9, color: hex(colors.ink)),
          encoding: (text: (field: series-field), color: (value: hex(colors.ink))),
        ),
      ),
    ),
    width,
    height,
  )
}

// Horizontal bars, longest first, with their values at their ends: revenue by region, say.
// `format` is the values' d3-format pattern, such as "$,.0f" for $1,180,000. (The bars are
// put in order here: Vega-Lite's own sort, "-x", fails in a chart with layers.)
#let bar-chart(values, category: "category", value: "value", format: ",.0f", width: 100%, height: 4.5cm) = chart(
  (
    data: (values: values),
    encoding: (
      y: (
        field: category,
        type: "nominal",
        sort: values.sorted(key: row => -row.at(value)).map(row => row.at(category)),
        axis: (labelFontSize: 10, labelColor: hex(colors.ink)),
      ),
      x: (
        field: value,
        type: "quantitative",
        axis: (format: format, tickCount: 4, labels: false, grid: false, domain: false, ticks: false),
      ),
    ),
    layer: (
      (mark: (type: "bar", cornerRadiusEnd: 3, height: (band: 0.6), color: hex(series.at(0)))),
      (
        mark: (type: "text", align: "left", dx: 5, fontSize: 9, color: hex(colors.ink)),
        encoding: (text: (field: value, type: "quantitative", format: format)),
      ),
    ),
  ),
  width,
  height,
)
