defmodule Typsty.ValueTest do
  use ExUnit.Case, async: true

  defmodule Point do
    @moduledoc false
    defstruct [:x, :y]
  end

  defmodule Money do
    @moduledoc false
    defstruct [:amount, :currency]
  end

  defimpl Typsty.Encoder, for: Money do
    def encode(%{amount: amount, currency: currency}), do: "#{amount} #{currency}"
  end

  defmodule Loop do
    @moduledoc false
    defstruct []
  end

  defimpl Typsty.Encoder, for: Loop do
    def encode(loop), do: loop
  end

  # Two structs that encode as each other
  defmodule PingPong.Ping do
    @moduledoc false
    defstruct []
  end

  defmodule PingPong.Pong do
    @moduledoc false
    defstruct []
  end

  defimpl Typsty.Encoder, for: PingPong.Ping do
    def encode(_ping), do: %PingPong.Pong{}
  end

  defimpl Typsty.Encoder, for: PingPong.Pong do
    def encode(_pong), do: %PingPong.Ping{}
  end

  alias PingPong.Ping
  alias Typsty.Test.Greeting

  # Each value is checked in Typst: the render fails if an assertion doesn't hold
  defp assert_typst(assertions, assigns) do
    assert {:ok, _pdf} = Typsty.to_pdf(assertions, assigns)
  end

  test "converts basic values" do
    assert_typst(
      ~S"""
      #assert.eq(none_value, none)
      #assert.eq(yes, true)
      #assert.eq(no, false)
      #assert.eq(type(an_integer), int)
      #assert.eq(an_integer, -42)
      #assert.eq(big, 9223372036854775807)
      #assert.eq(type(a_float), float)
      #assert.eq(a_float, 1.5)
      #assert.eq(string, "héllo ✓")
      #assert.eq(atom, "paid")
      """,
      %{
        none_value: nil,
        yes: true,
        no: false,
        an_integer: -42,
        big: 9_223_372_036_854_775_807,
        a_float: 1.5,
        string: "héllo ✓",
        atom: :paid
      }
    )
  end

  test "converts lists, tuples and maps" do
    assert_typst(
      ~S"""
      #assert.eq(list, (1, "two", (3,)))
      #assert.eq(empty, ())
      #assert.eq(tuple, (1, 2))
      #assert.eq(map.name, "Widget")
      #assert.eq(map.at("2024"), "integer key")
      #assert.eq(map.at("string key"), 1)
      #assert.eq(map.nested.deep, (true,))
      """,
      %{
        list: [1, "two", [3]],
        empty: [],
        tuple: {1, 2},
        map: %{:name => "Widget", 2024 => "integer key", "string key" => 1, nested: %{deep: [true]}}
      }
    )
  end

  test "converts dates and times" do
    assert_typst(
      ~S"""
      #assert.eq(date, datetime(year: 2026, month: 11, day: 23))
      #assert.eq(time, datetime(hour: 9, minute: 30, second: 15))
      #assert.eq(naive, datetime(year: 2026, month: 11, day: 23, hour: 9, minute: 30, second: 15))
      #assert.eq(utc, datetime(year: 2026, month: 11, day: 23, hour: 9, minute: 30, second: 15))
      #assert.eq(new-york, datetime(year: 2026, month: 11, day: 23, hour: 4, minute: 30, second: 15))
      #assert.eq(date.display("[month repr:long] [day], [year]"), "November 23, 2026")
      """,
      %{
        date: ~D[2026-11-23],
        time: ~T[09:30:15.123],
        naive: ~N[2026-11-23 09:30:15],
        utc: ~U[2026-11-23 09:30:15Z],
        # A DateTime keeps its wall time, rather than being converted to UTC
        "new-york": %DateTime{
          year: 2026,
          month: 11,
          day: 23,
          hour: 4,
          minute: 30,
          second: 15,
          microsecond: {0, 0},
          time_zone: "America/New_York",
          zone_abbr: "EST",
          utc_offset: -18_000,
          std_offset: 0
        }
      }
    )
  end

  test "converts decimals" do
    assert_typst(
      ~S"""
      #assert.eq(type(price), decimal)
      #assert.eq(price, decimal("19.99"))
      #assert.eq(price + tax, decimal("21.59"))
      #assert.eq(negative, decimal("-0.005"))
      #assert.eq(large, decimal("1200"))
      #assert.eq(zero, decimal("0.00"))
      """,
      %{
        price: Decimal.new("19.99"),
        tax: Decimal.new("1.60"),
        negative: Decimal.new("-0.005"),
        large: Decimal.new("1.2E+3"),
        zero: Decimal.new("0.00")
      }
    )
  end

  test "raises for decimals Typst can't represent" do
    assert_raise ArgumentError, ~r/price is a decimal that isn't a number \(NaN\)/, fn ->
      Typsty.to_pdf("x", %{price: Decimal.new("NaN")})
    end

    assert_raise ArgumentError, ~r/doesn't fit in a Typst decimal/, fn ->
      Typsty.to_pdf("x", %{price: Decimal.new("1E+40")})
    end
  end

  test "converts structs with Typsty.Encoder, or as maps" do
    assert_typst(
      ~S"""
      #assert.eq(point, (x: 1, y: 2))
      #assert.eq(price, "10 USD")
      """,
      %{point: %Point{x: 1, y: 2}, price: %Money{amount: 10, currency: "USD"}}
    )
  end

  test "raises for integers that don't fit in 64 bits" do
    assert_raise ArgumentError, ~r/big is an integer that doesn't fit in 64 bits/, fn ->
      Typsty.to_pdf("x", %{big: 9_223_372_036_854_775_808})
    end
  end

  test "raises for values that can't be converted, with their path" do
    assert_raise ArgumentError, ~r/invalid variables: items\[1\].owner is #PID/, fn ->
      Typsty.to_pdf("x", %{items: [%{}, %{owner: self()}]})
    end

    assert_raise ArgumentError, ~r/invalid variables: logo is a binary that isn't valid UTF-8/, fn ->
      Typsty.to_pdf("x", %{logo: <<0xFF, 0xFE>>})
    end

    assert_raise ArgumentError, ~r/invalid variables: list is an improper list/, fn ->
      Typsty.to_pdf("x", %{list: [1 | 2]})
    end

    assert_raise ArgumentError, ~r/invalid variables: map has the key 1.5/, fn ->
      Typsty.to_pdf("x", %{map: %{1.5 => 1}})
    end

    assert_raise ArgumentError, ~r/map has two keys that are both "a" once converted to strings/, fn ->
      Typsty.to_pdf("x", %{map: %{:a => 1, "a" => 2}})
    end

    assert_raise ArgumentError, ~r/the assigns has two keys that are both "name"/, fn ->
      Typsty.to_pdf("x", %{:name => 1, "name" => 2})
    end

    assert_raise ArgumentError, ~r/Loop struct that Typsty.Encoder encodes as itself/, fn ->
      Typsty.to_pdf("x", %{loop: %Loop{}})
    end

    assert_raise ArgumentError, ~r/PingPong.Ping struct, after 32 structs in a row/, fn ->
      Typsty.to_pdf("x", %{ping: %Ping{}})
    end

    assert_raise ArgumentError, ~r/invalid variables: nested is a Typsty.Template/, fn ->
      Typsty.to_pdf("x", %{nested: Greeting.render(%{name: "x"})})
    end

    assert_raise ArgumentError, ~r/must be strings, integers, or atoms other than nil/, fn ->
      Typsty.to_pdf("x", %{map: %{nil => 1}})
    end
  end

  test "refuses decimals with huge exponents before writing them out" do
    huge = %Decimal{sign: 1, coef: 1, exp: 500_000_000}
    tiny = %Decimal{sign: 1, coef: 1, exp: -500_000_000}

    for decimal <- [huge, tiny] do
      {micros, _} =
        :timer.tc(fn ->
          assert_raise ArgumentError, ~r/invalid variables: amount is a decimal with an exponent of/, fn ->
            Typsty.to_pdf("x", %{amount: decimal})
          end
        end)

      assert micros < 100_000
    end
  end
end
