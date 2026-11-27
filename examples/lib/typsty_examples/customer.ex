defmodule TypstyExamples.Customer do
  @moduledoc """
  A customer, as an application's Ecto schema might have it.

  Structs only reach templates when they implement `Typsty.Encoder`. Deriving it with
  `:only` passes the fields documents show, and leaves out internal ones like `:billing_id`.
  """
  @derive {Typsty.Encoder, only: [:name, :contact, :email, :address]}
  defstruct [:id, :name, :contact, :email, :address, :billing_id]
end
