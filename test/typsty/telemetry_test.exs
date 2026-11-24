defmodule Typsty.TelemetryTest do
  # Telemetry handlers are global
  use ExUnit.Case, async: false

  alias Typsty.Test.Greeting

  setup do
    handler_id = "typsty-telemetry-test"

    :telemetry.attach_many(
      handler_id,
      [[:typsty, :render, :start], [:typsty, :render, :stop], [:typsty, :render, :exception]],
      &__MODULE__.handle_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def handle_event(event, measurements, metadata, test_pid), do: send(test_pid, {event, measurements, metadata})

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
                     %{
                       module: nil,
                       format: :svg,
                       result: :error,
                       reason: :typst,
                       diagnostics: [%{message: "unknown variable: nobody"}]
                     }}
  end

  test "reports Typst's warnings in the stop event" do
    assert {:ok, _pdf} = Typsty.to_pdf(~S|#set text(font: "No Such Font")
Hello|)

    assert_received {[:typsty, :render, :stop], _measurements,
                     %{result: :ok, diagnostics: [%{severity: :warning, message: "unknown font family: no such font"}]}}
  end

  test "emits an exception event when rendering raises" do
    assert_raise ArgumentError, fn -> Typsty.to_png("x", %{"bad name" => 1}) end
    assert_received {[:typsty, :render, :exception], _measurements, %{format: :png, kind: :error}}
  end
end
