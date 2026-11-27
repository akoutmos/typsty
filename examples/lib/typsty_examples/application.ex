defmodule TypstyExamples.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      # For documents rendered from input that isn't well validated. See TypstyExamples.Pool
      {Typsty.Pool, name: TypstyExamples.Pool, size: 2, memory_limit: 1_000_000_000}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: TypstyExamples.Supervisor)
  end
end
