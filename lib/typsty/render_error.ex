defmodule Typsty.RenderError do
  @moduledoc """
  Rendering a document failed.

  - `:reason` - why it failed:
    - `:typst` - Typst reported errors: the template uses an assign that wasn't given, a
      value has the wrong type, a file, font or package is missing, and so on. For a
      template rendered from a string, this includes syntax errors (templates in document
      modules are checked when they compile).
    - `:timeout` - the render didn't finish within its `:timeout`.
    - `:busy` - the render didn't start within its `:timeout`: `:max_concurrent_renders`
      renders were already running, or every worker in its `Typsty.Pool` was busy, or being
      replaced (after a timeout, say).
    - `:memory_limit` - the render went over its `Typsty.Pool`'s `:memory_limit`.
    - `:crashed` - the render ended without a result: Typst crashed (a bug in Typst or
      Typsty, which extreme values can reach, such as a date past the year 9999), the
      pool's worker crashed, or the pool stopped.
  - `:diagnostics` - the errors, as `Typsty.Diagnostic` structs. For reasons other than
    `:typst`, it's a single error that says what happened.

  Timeouts and busy renders say more about the server's load than about the document, which
  an application can act on:

  ```elixir
  case MyApp.Invoice.to_pdf(assigns) do
    {:ok, pdf} ->
      send_download(conn, {:binary, pdf}, filename: "invoice.pdf")

    {:error, %Typsty.RenderError{reason: reason}} when reason in [:timeout, :busy] ->
      send_resp(conn, 503, "Please try again in a moment")

    {:error, %Typsty.RenderError{} = error} ->
      Logger.error(Exception.message(error))
      send_resp(conn, 500, "The invoice couldn't be generated")
  end
  ```
  """

  defexception reason: :typst, diagnostics: []

  @type reason :: :typst | :timeout | :busy | :memory_limit | :crashed

  @type t :: %__MODULE__{reason: reason(), diagnostics: [Typsty.Diagnostic.t()]}

  @impl Exception
  def message(%__MODULE__{diagnostics: diagnostics}) do
    "failed to render the Typst document:\n\n" <> Enum.map_join(diagnostics, "\n\n", &Typsty.Diagnostic.format/1)
  end
end
