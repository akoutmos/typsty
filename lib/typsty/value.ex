defmodule Typsty.Value do
  @moduledoc false

  # Converts the assigns into the terms the NIF turns into Typst values, which templates read
  # from the `assigns` dictionary:
  #
  # - nil, true and false
  # - integers, floats and UTF-8 strings
  # - lists and maps with string keys
  # - {:date, y, m, d}, {:time, h, m, s}, {:datetime, y, m, d, h, m, s} and {:decimal, string}
  #
  # Atoms become strings, tuples become lists, and structs go through Typsty.Encoder.

  # Typst recurses into values when it hashes, compares and prints them, and the NIF converts
  # them on a dirty scheduler's thread, whose stack is small, so deeply nested data is
  # refused (the native code has the same limit)
  @max_depth 128

  @max_int 9_223_372_036_854_775_807
  @min_int -9_223_372_036_854_775_808

  # Typst's decimals are integers below 2^96 (about 28 digits) scaled by up to 28 decimal
  # places. Their exponents are well within these bounds, which keep huge exponents from
  # being written out
  @max_decimal_exponent 40
  @max_decimal_integer Integer.pow(2, 96)
  @max_decimal_places 28
  @max_trimmed_zeros 1000
  @max_trimmable_coefficient Integer.pow(10, 1000)

  # Typst's dates go from year -9999 to 9999
  @max_year 9999

  # A range is passed as a list of its numbers or dates, which a range can make enormous
  @max_range_size 1_000_000

  # How many structs Typsty.Encoder may turn into other structs in a row, so that two
  # implementations that encode as each other can't loop forever
  @max_encodings 32

  # Keys that templates can read as fields (assigns.name), rather than with assigns.at("...")
  @field ~r/^[a-zA-Z_][a-zA-Z0-9_-]*$/

  @doc false
  @spec assigns(map()) :: %{String.t() => term()}
  def assigns(assigns) when is_map(assigns) and not is_struct(assigns), do: encode(assigns, [], 0)

  def assigns(assigns) do
    raise ArgumentError, "the assigns must be a map, got: #{inspect(assigns)}"
  end

  defp encode(value, _path, _encodings) when value in [nil, true, false], do: value
  defp encode(value, _path, _encodings) when is_atom(value), do: Atom.to_string(value)

  defp encode(value, path, _encodings) when is_integer(value) and (value > @max_int or value < @min_int) do
    invalid!(path, "is an integer that doesn't fit in 64 bits, which Typst integers are limited to")
  end

  defp encode(value, _path, _encodings) when is_number(value), do: value

  defp encode(value, path, _encodings) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      invalid!(path, "is a binary that isn't valid UTF-8. Pass binary data, like images, with the :files option")
    end
  end

  defp encode(value, path, _encodings) when is_list(value) do
    if not proper?(value), do: invalid!(path, "is an improper list")
    depth!(path)

    encode_list(value, path, 0)
  end

  defp encode(value, path, encodings) when is_tuple(value), do: value |> Tuple.to_list() |> encode(path, encodings)

  defp encode(%Date{} = date, path, _encodings) do
    %Date{year: year, month: month, day: day} = Date.convert!(date, Calendar.ISO)
    year!(year, path)
    {:date, year, month, day}
  end

  defp encode(%Time{} = time, _path, _encodings) do
    %Time{hour: hour, minute: minute, second: second} = Time.convert!(time, Calendar.ISO)
    {:time, hour, minute, second}
  end

  defp encode(%NaiveDateTime{} = datetime, path, _encodings) do
    datetime = NaiveDateTime.convert!(datetime, Calendar.ISO)
    year!(datetime.year, path)
    {:datetime, datetime.year, datetime.month, datetime.day, datetime.hour, datetime.minute, datetime.second}
  end

  # Typst datetimes have no time zone, so a DateTime keeps its wall time
  defp encode(%DateTime{} = datetime, path, encodings),
    do: datetime |> DateTime.to_naive() |> encode(path, encodings)

  defp encode(%{__struct__: Decimal, coef: coef}, path, _encodings) when not is_integer(coef) do
    invalid!(path, "is a decimal that isn't a number (#{coef}), which Typst decimals can't represent")
  end

  defp encode(%{__struct__: Decimal, coef: coef, exp: exp, sign: sign}, path, _encodings) do
    {coef, exp} = trim_zeros(coef, exp)

    # The coefficient is compared first, so that a huge one is refused without arithmetic
    if exp > @max_decimal_exponent or -exp > @max_decimal_places or coef >= @max_decimal_integer or
         coef * Integer.pow(10, max(exp, 0)) >= @max_decimal_integer do
      invalid!(
        path,
        "is a decimal that doesn't fit in a Typst decimal (about 28 significant digits, " <>
          "at most 28 of them after the decimal point)"
      )
    end

    {:decimal, decimal_string(sign, coef, exp)}
  end

  defp encode(%Range{} = range, path, _encodings) do
    if Range.size(range) > @max_range_size do
      invalid!(path, "is a range of #{Range.size(range)} numbers, more than #{@max_range_size}. Pass a list")
    end

    encode(Enum.to_list(range), path, 0)
  end

  # Each date is checked as it's converted, so a range that runs past Typst's years is
  # refused at the first date out of them
  defp encode(%Date.Range{} = range, path, _encodings) do
    size = Enum.count(range)

    if size > @max_range_size do
      invalid!(path, "is a range of #{size} dates, more than #{@max_range_size}. Pass its first and last dates")
    end

    encode(Enum.to_list(range), path, 0)
  end

  defp encode(%Typsty.Template{}, path, _encodings) do
    invalid!(
      path,
      "is a Typsty.Template, which can't be passed to another template. " <>
        "Pass the data it uses instead, or put its source in a .typ file and import it"
    )
  end

  defp encode(%module{}, path, encodings) when encodings >= @max_encodings do
    invalid!(
      path,
      "is a %#{inspect(module)}{} struct, after #{encodings} structs in a row were encoded as other structs"
    )
  end

  # An Ecto association that wasn't preloaded
  defp encode(%{__struct__: Ecto.Association.NotLoaded}, path, _encodings) do
    invalid!(
      path,
      "is an association that wasn't loaded: preload it, or leave it out " <>
        "(@derive {Typsty.Encoder, except: [...]})"
    )
  end

  defp encode(%module{} = struct, path, encodings) do
    if Typsty.Encoder.impl_for(struct) == nil do
      invalid!(
        path,
        "is a %#{inspect(module)}{} struct, which can only be passed to a template when it implements " <>
          "Typsty.Encoder: add @derive Typsty.Encoder (or @derive {Typsty.Encoder, only: [...]}) to " <>
          "its module, call Protocol.derive(Typsty.Encoder, #{inspect(module)}, only: [...]) for a struct " <>
          "from another library, or pass a map of the fields the template needs"
      )
    end

    case Typsty.Encoder.encode(struct) do
      %^module{} -> invalid!(path, "is a %#{inspect(module)}{} struct that Typsty.Encoder encodes as itself")
      encoded -> encode(encoded, path, encodings + 1)
    end
  end

  defp encode(value, path, _encodings) when is_map(value) do
    depth!(path)

    Enum.reduce(value, %{}, fn {key, item}, acc ->
      key = key!(key, path)

      if Map.has_key?(acc, key) do
        invalid!(path, "has two keys that are both #{inspect(key)} once converted to strings (like :name and \"name\")")
      end

      Map.put(acc, key, encode(item, [key | path], 0))
    end)
  end

  defp encode(value, path, _encodings) do
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
    invalid!(
      path,
      "has the key #{inspect(key)}. Keys must be strings, integers, or atoms other than nil, true and false"
    )
  end

  defp year!(year, _path) when year in -@max_year..@max_year//1, do: :ok

  defp year!(year, path) do
    invalid!(path, "is in the year #{year}, but Typst's dates go from the year -#{@max_year} to #{@max_year}")
  end

  defp depth!(path) do
    if length(path) >= @max_depth do
      invalid!(path, "is nested too deeply: lists and maps can be nested at most #{@max_depth} levels deep")
    end
  end

  defp proper?([]), do: true
  defp proper?([_ | tail]), do: proper?(tail)
  defp proper?(_tail), do: false

  # Without Enum.with_index/1, which would copy a large list once more
  defp encode_list([], _path, _index), do: []

  defp encode_list([item | rest], path, index),
    do: [encode(item, [index | path], 0) | encode_list(rest, path, index + 1)]

  # Trailing zeros after the decimal point that a Typst decimal has no room for are dropped,
  # so that 1.000…0 with 30 zeros (as multiplying decimals can give) is 1. Decimals far out of
  # range are left to be refused, rather than divided digit by digit. Zero always fits, with
  # as many of its places as fit (0E+41 comes from multiplying zero by 1E+41)
  defp trim_zeros(0, exp), do: {0, exp |> max(-@max_decimal_places) |> min(0)}

  defp trim_zeros(coef, exp)
       when exp < 0 and exp >= -@max_trimmed_zeros and coef < @max_trimmable_coefficient and rem(coef, 10) == 0 and
              (-exp > @max_decimal_places or coef >= @max_decimal_integer),
       do: trim_zeros(div(coef, 10), exp + 1)

  defp trim_zeros(coef, exp), do: {coef, exp}

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
    raise ArgumentError, "#{describe(path)} #{problem}"
  end

  # Where the value is, as a template reads it, such as assigns.items[1].name. The path is
  # innermost first. Deeply nested paths are shortened to their start and end.
  defp describe(path) when length(path) > 12 do
    {innermost, rest} = Enum.split(path, 4)
    describe(Enum.take(rest, -6)) <> "…" <> segments(innermost)
  end

  defp describe(path), do: "assigns" <> segments(path)

  defp segments(path), do: path |> Enum.reverse() |> Enum.map_join(&segment/1)

  defp segment(index) when is_integer(index), do: "[#{index}]"
  defp segment(key), do: if(key =~ @field, do: "." <> key, else: ".at(#{inspect(key)})")
end
