defprotocol Typsty.Encoder do
  @moduledoc """
  Converts structs into data that can be passed to a template.

  `Date`, `Time`, `NaiveDateTime`, `DateTime` and `Decimal` become Typst datetimes and
  decimals, and `MapSet`s, `Range`s and `Date.Range`s become arrays, without this
  protocol. Other structs must implement it to be passed to a template, so that their
  internal fields (an Ecto schema's metadata, or a password hash) don't reach templates by
  accident.

  Derive it to pass a struct as a dictionary of its fields, or of some of them:

  ```elixir
  defmodule MyApp.Customer do
    @derive {Typsty.Encoder, only: [:name, :email]}
    defstruct [:name, :email, :password_hash]
  end
  ```

  `@derive Typsty.Encoder` passes every field, and `except: [...]` leaves some out. An Ecto
  schema's `__meta__` field is always left out, and associations must be preloaded or left
  out. Fields in `:only` and `:except` that the struct doesn't have raise when it compiles.
  For structs from other libraries, derive it with `Protocol.derive/3`:

  ```elixir
  require Protocol
  Protocol.derive(Typsty.Encoder, SomeLibrary.Struct, only: [:name])
  ```

  Or implement it, to pass a struct differently, such as a money struct as a formatted
  string:

  ```elixir
  defimpl Typsty.Encoder, for: MyApp.Money do
    def encode(money), do: MyApp.Money.to_string(money)
  end
  ```

  `encode/1` can return any data a template accepts: maps, lists, strings, numbers,
  booleans, `nil`, dates and decimals, or another struct.
  """

  @doc "Converts the struct into data for a template."
  @spec encode(t()) :: term()
  def encode(struct)

  @impl Protocol
  defmacro __deriving__(module, options) do
    options = Keyword.validate!(options, [:only, :except])
    struct_fields = for %{field: field} <- Macro.struct_info!(module, __CALLER__), do: field

    for {option, fields} <- options, is_list(fields), (unknown = fields -- struct_fields) != [] do
      raise ArgumentError,
            "deriving Typsty.Encoder for #{inspect(module)}: #{inspect(option)} has fields " <>
              "the struct doesn't have: #{inspect(unknown)}"
    end

    # An Ecto schema's metadata, which templates have no use for
    fields =
      case options do
        [] -> quote(do: Map.delete(map, :__meta__))
        [only: only] when is_list(only) -> quote(do: Map.take(map, unquote(only)))
        [except: except] when is_list(except) -> quote(do: Map.drop(map, [:__meta__ | unquote(except)]))
        _other -> raise ArgumentError, "deriving Typsty.Encoder takes either :only or :except, as a list of fields"
      end

    quote do
      defimpl Typsty.Encoder, for: unquote(module) do
        def encode(struct) do
          map = Map.from_struct(struct)
          unquote(fields)
        end
      end
    end
  end
end

defimpl Typsty.Encoder, for: MapSet do
  # In order, so that the same set gives the same array. Dates, times and decimals are sorted
  # by value: in Erlang's term order, their structs would sort field by field, which puts
  # dates in order of their day of the month
  @by_value [Date, Time, NaiveDateTime, DateTime, Decimal]

  def encode(set) do
    members = MapSet.to_list(set)

    case members do
      [%module{} | _] when module in @by_value ->
        if Enum.all?(members, &comparable?(&1, module)), do: Enum.sort(members, module), else: Enum.sort(members)

      _members ->
        Enum.sort(members)
    end
  end

  # Decimals that aren't numbers (NaN, infinity) can't be compared, and are refused once
  # they're encoded, as they are outside a set
  defp comparable?(%{__struct__: Decimal, coef: coef}, Decimal), do: is_integer(coef)
  defp comparable?(member, module), do: is_struct(member, module)
end
