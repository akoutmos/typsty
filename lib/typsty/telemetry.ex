defmodule Typsty.Telemetry do
  @moduledoc """
  Telemetry events for rendering documents.

  Typsty emits these events whenever a document is rendered, with `:telemetry.span/3`:

  * `[:typsty, :render, :start]` - rendering has begun
  * `[:typsty, :render, :stop]` - rendering has finished, successfully or with Typst errors
  * `[:typsty, :render, :exception]` - rendering raised, for example because of invalid
    options or variables

  | event        | measurements   | metadata                                                    |
  | ------------ | -------------- | ----------------------------------------------------------- |
  | `:start`     | `:system_time` | `:module`, `:format`, `:template`                           |
  | `:stop`      | `:duration`    | `:module`, `:format`, `:template`, `:result`, `:diagnostics` |
  | `:exception` | `:duration`    | `:module`, `:format`, `:template`, `:kind`, `:reason`, `:stacktrace` |

  - `:module` - the document module, or `nil` for a template rendered with `Typsty.to_pdf/3`
    and the like.
  - `:format` - `:pdf`, `:png` or `:svg`.
  - `:template` - the `Typsty.Template` that was rendered, with its assigns.
  - `:result` - `:ok`, or `:error` when Typst reported errors.
  - `:diagnostics` - the warnings when the document rendered, or the errors when it didn't,
    as `Typsty.Diagnostic` structs.
  """
end
