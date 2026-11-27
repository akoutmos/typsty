# Used by "mix format". Typsty.Formatter formats ~TYPST sigils and .typ templates
[
  plugins: [Typsty.Formatter],
  import_deps: [:typsty],
  line_length: 120,
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs,typ}"]
]
