import Config

config :typsty,
  package_paths: [Application.app_dir(:typsty_examples, "priv/typst/packages")],
  # Only the fonts that come with Typst, so the examples look the same on every machine
  system_fonts: false
