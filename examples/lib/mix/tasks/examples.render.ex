defmodule Mix.Tasks.Examples.Render do
  @shortdoc "Renders the examples into output/"
  @moduledoc """
  Renders the examples with their sample data into `output/`.

      mix examples.render                 # every example, as PDFs
      mix examples.render invoice report  # some of them
      mix examples.render --png           # PNGs of each page, as well
      mix examples.render --pool          # in TypstyExamples.Pool, rather than in the VM

  Run `mix typsty.packages.get` first, to download the packages the examples use.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    {opts, names} = OptionParser.parse!(args, strict: [png: :boolean, pool: :boolean, ppi: :integer])
    render_opts = if opts[:pool], do: [pool: TypstyExamples.Pool], else: []
    File.mkdir_p!("output")

    for {name, module, assigns, example_opts} <- examples(names) do
      opts_for = &Keyword.merge(example_opts, render_opts ++ &1)
      {microseconds, pdf} = :timer.tc(fn -> module.to_pdf!(assigns, opts_for.([])) end)
      File.write!("output/#{name}.pdf", pdf)
      Mix.shell().info("* output/#{name}.pdf (#{div(microseconds, 1000)} ms)")

      if opts[:png] do
        for {png, page} <- Enum.with_index(module.to_png!(assigns, opts_for.(ppi: opts[:ppi] || 110)), 1) do
          File.write!("output/#{name}-#{page}.png", png)
        end
      end
    end
  end

  defp examples([]), do: TypstyExamples.all()

  defp examples(names) do
    Enum.map(names, fn name ->
      TypstyExamples.get(name) || Mix.raise("there's no example named #{name}")
    end)
  end
end
