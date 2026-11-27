defmodule Typsty.ValueTest do
  use ExUnit.Case, async: true

  defmodule Point do
    @moduledoc false
    @derive Typsty.Encoder
    defstruct [:x, :y]
  end

  defmodule Customer do
    @moduledoc false
    @derive {Typsty.Encoder, only: [:name]}
    defstruct [:name, :password_hash]
  end

  defmodule Secret do
    @moduledoc false
    @derive {Typsty.Encoder, except: [:token]}
    defstruct [:id, :token]
  end

  defmodule Plain do
    @moduledoc false
    defstruct [:value]
  end

  # Like an Ecto schema, whose metadata is a struct of its own
  defmodule Schema do
    @moduledoc false
    @derive Typsty.Encoder
    defstruct __meta__: %Plain{}, name: nil
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
      #assert.eq(assigns.none_value, none)
      #assert.eq(assigns.yes, true)
      #assert.eq(assigns.no, false)
      #assert.eq(type(assigns.an_integer), int)
      #assert.eq(assigns.an_integer, -42)
      #assert.eq(assigns.big, 9223372036854775807)
      #assert.eq(type(assigns.a_float), float)
      #assert.eq(assigns.a_float, 1.5)
      #assert.eq(assigns.string, "héllo ✓")
      #assert.eq(assigns.atom, "paid")
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
      #assert.eq(assigns.list, (1, "two", (3,)))
      #assert.eq(assigns.empty, ())
      #assert.eq(assigns.tuple, (1, 2))
      #assert.eq(assigns.map.name, "Widget")
      #assert.eq(assigns.map.at("2024"), "integer key")
      #assert.eq(assigns.map.at("string key"), 1)
      #assert.eq(assigns.map.nested.deep, (true,))
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
      #assert.eq(assigns.date, datetime(year: 2026, month: 11, day: 23))
      #assert.eq(assigns.time, datetime(hour: 9, minute: 30, second: 15))
      #assert.eq(assigns.naive, datetime(year: 2026, month: 11, day: 23, hour: 9, minute: 30, second: 15))
      #assert.eq(assigns.utc, datetime(year: 2026, month: 11, day: 23, hour: 9, minute: 30, second: 15))
      #assert.eq(assigns.new-york, datetime(year: 2026, month: 11, day: 23, hour: 4, minute: 30, second: 15))
      #assert.eq(assigns.date.display("[month repr:long] [day], [year]"), "November 23, 2026")
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
      #assert.eq(type(assigns.price), decimal)
      #assert.eq(assigns.price, decimal("19.99"))
      #assert.eq(assigns.price + assigns.tax, decimal("21.59"))
      #assert.eq(assigns.negative, decimal("-0.005"))
      #assert.eq(assigns.large, decimal("1200"))
      #assert.eq(assigns.zero, decimal("0.00"))
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

  test "converts structs that implement or derive Typsty.Encoder" do
    assert_typst(
      ~S"""
      #assert.eq(assigns.point, (x: 1, y: 2))
      #assert.eq(assigns.price, "10 USD")
      #assert.eq(assigns.customer, (name: "Ada"))
      #assert.eq(assigns.secret, (id: 7))
      #assert.eq(assigns.set, ("a", "b"))
      #assert.eq(assigns.range, (1, 2, 3))
      """,
      %{
        point: %Point{x: 1, y: 2},
        price: %Money{amount: 10, currency: "USD"},
        customer: %Customer{name: "Ada", password_hash: "x"},
        secret: %Secret{id: 7, token: "x"},
        set: MapSet.new(["b", "a"]),
        range: 1..3
      }
    )
  end

  test "converts a Date.Range to an array of its dates, in steps and backwards" do
    assert_typst(
      ~S"""
      #let october(day) = datetime(year: 2026, month: 10, day: day)
      #assert.eq(assigns.month.len(), 31)
      #assert.eq(assigns.month.first(), october(1))
      #assert.eq(assigns.month.last(), october(31))
      #assert.eq(assigns.weekly, (october(1), october(8), october(15)))
      #assert.eq(assigns.backwards, (october(3), october(2), october(1)))
      #assert.eq(assigns.empty, ())
      """,
      %{
        month: Date.range(~D[2026-10-01], ~D[2026-10-31]),
        weekly: Date.range(~D[2026-10-01], ~D[2026-10-20], 7),
        backwards: Date.range(~D[2026-10-03], ~D[2026-10-01], -1),
        empty: Date.range(~D[2026-10-02], ~D[2026-10-01], 1)
      }
    )
  end

  test "refuses structs that don't implement Typsty.Encoder, rather than pass their fields" do
    assert_raise ArgumentError,
                 ~r/^assigns.plain is a %Typsty.ValueTest.Plain{} struct, which can only be passed/,
                 fn ->
                   Typsty.to_pdf("x", %{plain: %Plain{value: 1}})
                 end

    assert_raise ArgumentError, ~r/^assigns.range is a range of 2000000 numbers/, fn ->
      Typsty.to_pdf("x", %{range: 1..2_000_000})
    end

    assert_raise ArgumentError, ~r/^assigns.period is a range of 3652059 dates, more than 1000000\./, fn ->
      Typsty.to_pdf("x", %{period: Date.range(~D[0001-01-01], ~D[9999-12-31])})
    end
  end

  test "refuses dates and decimals Typst can't represent, with their path" do
    assert_raise ArgumentError, ~r/^assigns.d is in the year 10000/, fn ->
      Typsty.to_pdf("x", %{d: Date.new!(10_000, 1, 1)})
    end

    assert_raise ArgumentError, ~r/^assigns.period\[1\] is in the year 10000/, fn ->
      Typsty.to_pdf("x", %{period: Date.range(~D[9999-12-31], Date.new!(10_000, 1, 1))})
    end

    for decimal <- ["79228162514264337593543950336", "1E-29", "1E+29"] do
      assert_raise ArgumentError, ~r/^assigns.x is a decimal that doesn't fit in a Typst decimal/, fn ->
        Typsty.to_pdf("x", %{x: Decimal.new(decimal)})
      end
    end

    assert {:ok, _pdf} = Typsty.to_pdf("#assigns.x", %{x: Decimal.new("79228162514264337593543950335")})
  end

  test "drops trailing zeros that don't fit in a Typst decimal, and only those" do
    one = Decimal.mult(Decimal.new("1.00000000000000000"), Decimal.new("1.0000000000000"))
    assert one.exp == -30

    assert_typst(
      ~S"""
      #assert.eq(assigns.one, decimal("1"))
      #assert.eq(str(assigns.price), "19.50")
      """,
      %{one: one, price: Decimal.new("19.50")}
    )
  end

  test "refuses huge decimals without working through their digits" do
    {time, _} =
      :timer.tc(fn ->
        assert_raise ArgumentError, ~r/doesn't fit in a Typst decimal/, fn ->
          Typsty.to_pdf("x", %{x: %Decimal{sign: 1, coef: Integer.pow(10, 200_000) + 1, exp: -5}})
        end
      end)

    assert time < 1_000_000
  end

  test "deriving Typsty.Encoder leaves an Ecto schema's metadata out, and checks the fields it names" do
    assert_typst(~S|#assert.eq(assigns.schema, (name: "Ada"))|, %{schema: %Schema{name: "Ada"}})

    assert_raise ArgumentError, ~r/:only has fields the struct doesn't have: \[:nmae\]/, fn ->
      Code.compile_string("""
      defmodule Typsty.ValueTest.Typo do
        @derive {Typsty.Encoder, only: [:nmae]}
        defstruct [:name]
      end
      """)
    end
  end

  test "deriving Typsty.Encoder takes :only or :except, as a list of fields" do
    derive = fn options ->
      Code.compile_string("""
      defmodule Typsty.ValueTest.BadDerive do
        @derive {Typsty.Encoder, #{options}}
        defstruct [:name, :token]
      end
      """)
    end

    for options <- ["only: :name", "except: :token", "only: [:name], except: [:token]"] do
      assert_raise ArgumentError, "deriving Typsty.Encoder takes either :only or :except, as a list of fields", fn ->
        derive.(options)
      end
    end

    assert_raise ArgumentError, ~r/unknown keys \[:fields\]/, fn -> derive.("fields: [:name]") end
  end

  test "refuses keys that aren't valid UTF-8, and associations that weren't loaded, with their path" do
    assert_raise ArgumentError, ~r/^assigns.customer has a key that isn't valid UTF-8: <<255>>/, fn ->
      Typsty.to_pdf("x", %{customer: %{<<255>> => 1}})
    end

    # What Ecto puts in a schema's association until it's preloaded
    not_loaded = %{__struct__: Ecto.Association.NotLoaded, __field__: :orders, __cardinality__: :many}

    assert_raise ArgumentError, ~r/^assigns.customer.orders is an association that wasn't loaded: preload it/, fn ->
      Typsty.to_pdf("x", %{customer: %{orders: not_loaded}})
    end
  end

  test "raises for integers that don't fit in 64 bits" do
    assert_raise ArgumentError, ~r/big is an integer that doesn't fit in 64 bits/, fn ->
      Typsty.to_pdf("x", %{big: 9_223_372_036_854_775_808})
    end
  end

  test "raises for values that can't be converted, with their path" do
    assert_raise ArgumentError, ~r/^assigns.items\[1\].owner is #PID/, fn ->
      Typsty.to_pdf("x", %{items: [%{}, %{owner: self()}]})
    end

    assert_raise ArgumentError, ~r/^assigns.logo is a binary that isn't valid UTF-8/, fn ->
      Typsty.to_pdf("x", %{logo: <<0xFF, 0xFE>>})
    end

    assert_raise ArgumentError, ~r/^assigns.list is an improper list/, fn ->
      Typsty.to_pdf("x", %{list: [1 | 2]})
    end

    assert_raise ArgumentError, ~r/^assigns.map has the key 1.5/, fn ->
      Typsty.to_pdf("x", %{map: %{1.5 => 1}})
    end

    assert_raise ArgumentError, ~r/map has two keys that are both "a" once converted to strings/, fn ->
      Typsty.to_pdf("x", %{map: %{:a => 1, "a" => 2}})
    end

    assert_raise ArgumentError, ~r/^assigns has two keys that are both "name"/, fn ->
      Typsty.to_pdf("x", %{:name => 1, "name" => 2})
    end

    assert_raise ArgumentError, ~r/%Typsty.ValueTest.Loop{} struct that Typsty.Encoder encodes as itself/, fn ->
      Typsty.to_pdf("x", %{loop: %Loop{}})
    end

    assert_raise ArgumentError, ~r/PingPong.Ping{} struct, after 32 structs in a row/, fn ->
      Typsty.to_pdf("x", %{ping: %Ping{}})
    end

    assert_raise ArgumentError, ~r/^assigns.nested is a Typsty.Template/, fn ->
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
          assert_raise ArgumentError, ~r/^assigns.amount is a decimal that doesn't fit/, fn ->
            Typsty.to_pdf("x", %{amount: decimal})
          end
        end)

      assert micros < 100_000
    end
  end
end
