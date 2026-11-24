defprotocol Typsty.Encoder do
  @moduledoc """
  Converts structs into data that can be passed to a template.

  Structs without an implementation are passed as dictionaries of their fields. `Date`,
  `Time`, `NaiveDateTime` and `DateTime` become Typst datetimes, and `Decimal` becomes a
  Typst decimal, without going through this protocol.

  Implement it to pass a struct differently, such as a money struct as a decimal or as a
  formatted string:

  ```elixir
  defimpl Typsty.Encoder, for: Money do
    def encode(money), do: Money.to_string(money)
  end
  ```

  `encode/1` can return any data a template accepts: maps, lists, strings, numbers,
  booleans, `nil`, dates and decimals, or another struct.
  """

  @fallback_to_any true

  @doc "Converts the struct into data for a template."
  @spec encode(t()) :: term()
  def encode(struct)
end

defimpl Typsty.Encoder, for: Any do
  def encode(%_{} = struct), do: Map.from_struct(struct)
end
