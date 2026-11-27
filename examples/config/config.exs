import Config

# The Typst packages the templates import, which `mix typsty.packages.get` downloads into
# priv/typst/packages
config :typsty, packages: ["@preview/nulite:0.2.0", "@preview/tiaoma:0.4.0"]
