defmodule TypstyExamples do
  @moduledoc """
  Example documents rendered with Typsty, with sample data. See the README.
  """

  alias TypstyExamples.Samples

  @doc """
  Every example: its name, its document module, and the assigns and options it renders
  with.
  """
  def all do
    [
      {"invoice", TypstyExamples.Invoice, Samples.invoice(), []},
      {"report", TypstyExamples.Report, Samples.report(), []},
      {"cheat_sheet", TypstyExamples.CheatSheet, Samples.cheat_sheet(), []},
      {"statement", TypstyExamples.Statement, Samples.statement(), []},
      {"tickets", TypstyExamples.Tickets, Samples.tickets(), []},
      {"shipping_label", TypstyExamples.ShippingLabel, Samples.shipping_label(), []},
      {"certificate", TypstyExamples.Certificate, Samples.certificate(), files: Samples.certificate_files()}
    ]
  end

  @doc "The example with this name, or nil."
  def get(name), do: Enum.find(all(), &(elem(&1, 0) == name))
end
