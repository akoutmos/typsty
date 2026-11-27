// Paths here are relative to this file, in the component's folder
#let caption = read("caption.txt").trim()
#let framed(body) = rect(inset: 4pt)[#body #emph(caption)]
#let broken() = "a" + 1
