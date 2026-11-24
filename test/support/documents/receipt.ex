defmodule Typsty.Test.Receipt do
  @moduledoc false
  use Typsty, template: "templates/receipt_template.typ"

  # Defaults files for every render, through the overridable to_pdf/2
  def to_pdf(assigns, opts) do
    super(assigns, Keyword.put_new(opts, :files, %{"note.txt" => "Thank you!"}))
  end
end
