defmodule Typsty.Telemetry do
  @moduledoc """
  Telemetry events for rendering documents.

  Typsty emits these events whenever a document is rendered, with `:telemetry.span/3`:

  * `[:typsty, :render, :start]` - rendering has begun
  * `[:typsty, :render, :stop]` - rendering has finished, successfully or with an error
  * `[:typsty, :render, :exception]` - rendering raised, for example because of invalid
    options or variables

  | event        | measurements                       | metadata                                                              |
  | ------------ | ---------------------------------- | --------------------------------------------------------------------- |
  | `:start`     | `:system_time`, `:monotonic_time`  | `:module`, `:format`, `:template`                                     |
  | `:stop`      | `:duration`, `:monotonic_time`     | `:module`, `:format`, `:template`, `:result`, `:reason`, `:diagnostics` |
  | `:exception` | `:duration`, `:monotonic_time`     | `:module`, `:format`, `:template`, `:kind`, `:reason`, `:stacktrace`  |

  - `:duration` - how long rendering took, in native time units (convert it with
    `System.convert_time_unit/3`). It covers rendering the template, not a document
    module's `render/1`, which runs first.
  - `:module` - the document module, or `nil` for a template rendered with `Typsty.to_pdf/3`
    and the like.
  - `:format` - `:pdf`, `:png` or `:svg`.
  - `:template` - the `Typsty.Template` that was rendered, with its assigns.
  - `:result` - `:ok`, or `:error` when the document couldn't be rendered.
  - `:reason` - for `:stop` events with an `:error` result, why: the `:reason` of the
    `Typsty.RenderError`. For `:exception` events, the exception.
  - `:diagnostics` - the warnings when the document rendered, or the errors when it didn't,
    as `Typsty.Diagnostic` structs.

  Every event's metadata also has `:telemetry_span_context`, which ties the events of a
  render together.
  """
end
