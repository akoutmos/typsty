defmodule Typsty.Value do
  @moduledoc false

  # Converts Elixir data into the terms the NIF turns into Typst values:
  #
  # - nil, true and false
  # - integers, floats and UTF-8 strings
  # - lists and maps with string keys
  # - {:date, y, m, d}, {:time, h, m, s}, {:datetime, y, m, d, h, m, s} and {:decimal, string}
  #
  # Atoms become strings, tuples become lists, and structs go through Typsty.Encoder.

  # Typst recurses into values when it hashes, compares and prints them, so deeply nested
  # data is refused (the native code has the same limit)
  @max_depth 256

  @max_int 9_223_372_036_854_775_807
  @min_int -9_223_372_036_854_775_808

  @doc false
  @spec variables(map() | keyword()) :: %{String.t() => term()}
  def variables(assigns) when is_map(assigns) or is_list(assigns) do
    if is_list(assigns) and not Keyword.keyword?(assigns) do
      raise ArgumentError, "the variables must be a map or a keyword list, got: #{inspect(assigns)}"
    end

    assigns
    |> Map.new()
    |> encode([])
  end

  def variables(assigns) do
    raise ArgumentError, "the variables must be a map or a keyword list, got: #{inspect(assigns)}"
  end

  defp encode(value, _path) when value in [nil, true, false], do: value
  defp encode(value, _path) when is_atom(value), do: Atom.to_string(value)

  defp encode(value, path) when is_integer(value) and (value > @max_int or value < @min_int) do
    invalid!(path, "is an integer that doesn't fit in 64 bits, which Typst integers are limited to")
  end

  defp encode(value, _path) when is_number(value), do: value

  defp encode(value, path) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      invalid!(path, "is a binary that isn't valid UTF-8. Pass binary data, like images, with the :files option")
    end
  end

  defp encode(value, path) when is_list(value) do
    if not proper?(value), do: invalid!(path, "is an improper list")
    depth!(path)

    value
    |> Enum.with_index()
    |> Enum.map(fn {item, index} -> encode(item, [index | path]) end)
  end

  defp encode(value, path) when is_tuple(value), do: value |> Tuple.to_list() |> encode(path)

  defp encode(%Date{} = date, _path) do
    %Date{year: year, month: month, day: day} = Date.convert!(date, Calendar.ISO)
    {:date, year, month, day}
  end

  defp encode(%Time{} = time, _path) do
    %Time{hour: hour, minute: minute, second: second} = Time.convert!(time, Calendar.ISO)
    {:time, hour, minute, second}
  end

  defp encode(%NaiveDateTime{} = datetime, _path) do
    datetime = NaiveDateTime.convert!(datetime, Calendar.ISO)
    {:datetime, datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, datetime.second}
  end

  # Typst datetimes have no time zone, so a DateTime keeps its wall time
  defp encode(%DateTime{} = datetime, path), do: datetime |> DateTime.to_naive() |> encode(path)

  defp encode(%{__struct__: Decimal, coef: coef, exp: exp, sign: sign}, path) do
    if is_integer(coef) do
      {:decimal, decimal_string(sign, coef, exp)}
    else
      invalid!(path, "is a decimal that isn't a number (#{coef}), which Typst decimals can't represent")
    end
  end

  defp encode(%module{} = struct, path) do
    case Typsty.Encoder.encode(struct) do
      %^module{} -> invalid!(path, "is a #{inspect(module)} struct that Typsty.Encoder encodes as itself")
      encoded -> encode(encoded, path)
    end
  end

  defp encode(value, path) when is_map(value) do
    depth!(path)

    Enum.reduce(value, %{}, fn {key, item}, acc ->
      key = key!(key, path)

      if Map.has_key?(acc, key) do
        invalid!(path, "has the key #{inspect(key)} more than once, once the keys are converted to strings")
      end

      Map.put(acc, key, encode(item, [key | path]))
    end)
  end

  defp encode(value, path) do
    invalid!(path, "is #{inspect(value)}, which can't be passed to Typst")
  end

  defp key!(key, path) when is_binary(key) do
    if String.valid?(key) do
      key
    else
      invalid!(path, "has a key that isn't valid UTF-8: #{inspect(key)}")
    end
  end

  defp key!(key, _path) when is_atom(key) and key not in [nil, true, false], do: Atom.to_string(key)
  defp key!(key, _path) when is_integer(key), do: Integer.to_string(key)

  defp key!(key, path) do
    invalid!(path, "has the key #{inspect(key)}. Keys must be atoms, strings or integers")
  end

  defp depth!(path) do
    if length(path) >= @max_depth do
      invalid!(path, "is nested too deeply: lists and maps can be nested at most #{@max_depth} levels deep")
    end
  end

  defp proper?([]), do: true
  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?(_tail), do: false

  # Decimal.to_string(decimal, :normal), without depending on Decimal
  defp decimal_string(sign, coef, exp) do
    digits = Integer.to_string(coef)

    unsigned =
      cond do
        exp >= 0 ->
          digits <> String.duplicate("0", exp)

        -exp >= byte_size(digits) ->
          "0." <> String.duplicate("0", -exp - byte_size(digits)) <> digits

        true ->
          {integer, fraction} = String.split_at(digits, byte_size(digits) + exp)
          integer <> "." <> fraction
      end

    if sign < 0, do: "-" <> unsigned, else: unsigned
  end

  defp invalid!(path, problem) do
    raise ArgumentError, "invalid variables: #{describe(path)} #{problem}"
  end

  defp describe([]), do: "the value"

  # Deeply nested paths are shortened to their start and end
  defp describe(path) when length(path) > 12 do
    {last, rest} = Enum.split(path, 4)
    describe(Enum.take(rest, -6)) <> "…" <> (last |> Enum.reverse() |> join_path(true))
  end

  defp describe(path), do: path |> Enum.reverse() |> join_path(false)

  defp join_path(segments, continued?) do
    initial = if continued?, do: :continued, else: ""

    segments
    |> Enum.reduce(initial, fn
      index, :continued when is_integer(index) -> "[#{index}]"
      key, :continued -> "." <> key
      index, "" when is_integer(index) -> "[#{index}]"
      index, acc when is_integer(index) -> acc <> "[#{index}]"
      key, "" -> key
      key, acc -> acc <> "." <> key
    end)
  end
end
