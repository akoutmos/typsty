defmodule Typsty.TelemetryTest do
  # Telemetry handlers are global
  use ExUnit.Case, async: false

  alias Typsty.Test.Greeting

  setup do
    test_pid = self()
    handler_id = "typsty-telemetry-test"

    :telemetry.attach_many(
      handler_id,
      [[:typsty, :render, :start], [:typsty, :render, :stop], [:typsty, :render, :exception]],
      fn event, measurements, metadata, _config -> send(test_pid, {event, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "emits start and stop events for a document module" do
    assert {:ok, _pdf} = Greeting.to_pdf(%{name: "World", items: []})

    assert_received {[:typsty, :render, :start], %{system_time: _},
                     %{module: Greeting, format: :pdf, template: template}}

    assert template.assigns.name == "World"

    assert_received {[:typsty, :render, :stop], %{duration: _}, %{module: Greeting, result: :ok, diagnostics: []}}
  end

  test "reports Typst errors in the stop event" do
    assert {:error, _error} = Typsty.to_svg("#nobody")

    assert_received {[:typsty, :render, :stop], _measurements,
                     %{module: nil, format: :svg, result: :error, diagnostics: [%{message: "unknown variable: nobody"}]}}
  end

  test "emits an exception event when rendering raises" do
    assert_raise ArgumentError, fn -> Typsty.to_png("x", %{"bad name" => 1}) end
    assert_received {[:typsty, :render, :exception], _measurements, %{format: :png, kind: :error}}
  end
end
