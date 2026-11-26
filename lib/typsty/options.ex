defmodule Typsty.Options do
  @moduledoc false

  # The options Typsty's functions take, as NimbleOptions schemas, which both validate them
  # and document them (the docs of Typsty, Typsty.Pool and so on are generated from them).
  #
  # Invalid options raise ArgumentError with NimbleOptions' message, like the other invalid
  # arguments. The rendering options can also be set in the application config, which is
  # validated too, so that a typo there is caught; its errors say they're in the config.

  # The PDF standards Typst supports (typsty_core::export::pdf_standard)
  @pdf_standards ~w(1.4 1.5 1.6 1.7 2.0 a-1b a-1a a-2b a-2u a-2a a-3b a-3u a-3a a-4 a-4f a-4e ua-1)

  # The longest a receive can wait
  @max_timeout 4_294_967_295

  # Bounds for numbers that are only sensible well below them, so that the native code can
  # take them (it can't take integers past 64 bits)
  @max_count 10_000
  @max_ppi 10_000

  @render [
    files: [
      type: {:custom, __MODULE__, :files, []},
      type_doc: "a map of paths to binaries, or a list of `{path, binary}` tuples",
      type_spec: quote(do: %{optional(String.t()) => binary()} | [{String.t(), binary()}]),
      doc: """
      The files the document reads, such as images, data files and other `.typ` files, as
      binaries, by their path in the project (see [Files](Typsty.html#module-files)). This
      option can't be set in the config.
      """
    ],
    root: [
      type: {:custom, __MODULE__, :optional_path, []},
      type_doc: "`t:Path.t/0` or `nil`",
      type_spec: quote(do: Path.t() | nil),
      default: nil,
      doc: """
      A directory to read the files that aren't in `:files` from. Documents can't read
      outside it, even through symbolic links.
      """
    ],
    font_paths: [
      type: {:custom, __MODULE__, :paths, []},
      type_doc: "list of `t:Path.t/0`",
      type_spec: quote(do: [Path.t()]),
      default: [],
      doc: """
      Directories to load fonts from, searched recursively. Relative paths are relative to
      the current directory when the document renders, which in a release isn't your app's
      directory: use `Application.app_dir/2`, in `config/runtime.exs`.
      """
    ],
    system_fonts: [
      type: :boolean,
      default: true,
      doc: """
      Whether to use the fonts installed on the system. Turn it off for documents that render
      the same on every machine.
      """
    ],
    embedded_fonts: [
      type: :boolean,
      default: true,
      doc: """
      Whether to use the fonts that come with Typst (Libertinus Serif, New Computer Modern,
      New Computer Modern Math and DejaVu Sans Mono).
      """
    ],
    package_paths: [
      type: {:custom, __MODULE__, :paths, []},
      type_doc: "list of `t:Path.t/0`",
      type_spec: quote(do: [Path.t()]),
      default: [],
      doc: """
      Directories with Typst packages, laid out as `namespace/name/version`, like Typst's
      package cache. A template can import a package from them with
      `#import "@preview/cetz:0.4.2"`. Packages are never downloaded while rendering: fetch
      them ahead of time with `mix typsty.packages.get`.
      """
    ],
    ppi: [
      type: {:custom, __MODULE__, :positive_number, [@max_ppi]},
      type_doc: "positive number (at most #{@max_ppi})",
      type_spec: quote(do: number()),
      default: 144,
      doc: "For PNG, the resolution in pixels per inch."
    ],
    pdf_standards: [
      type: {:list, {:in, @pdf_standards}},
      type_doc: "list of `t:String.t/0`",
      type_spec: quote(do: [String.t()]),
      default: [],
      doc: """
      For PDF, the standards to conform to: any of #{Enum.map_join(@pdf_standards, ", ", &~s(`"#{&1}"`))},
      such as `["a-2b"]` for PDF/A-2b or `["ua-1"]` for PDF/UA-1. PDF/A needs the document's
      date, which is the time of the render unless the template sets it with
      `#set document(date: ...)`.
      """
    ],
    timeout: [
      type: {:custom, __MODULE__, :timeout, []},
      type_doc: "`t:timeout/0`",
      type_spec: quote(do: timeout()),
      default: 60_000,
      doc: """
      How long to wait for the render, in milliseconds (at most `4_294_967_295`), or
      `:infinity`, including the time spent waiting for a free slot (see
      `:max_concurrent_renders`). A render that times out returns an error and is cancelled:
      it stops the next time Typst lays out content, loads a file or a font, or exports a PNG
      or SVG page, which for most documents is within milliseconds. A template doing pure
      computation (a long loop of arithmetic) keeps running until it gets to one of those.
      In a `Typsty.Pool`, a render that times out is stopped right away.
      """
    ],
    pool: [
      type: {:custom, __MODULE__, :pool, []},
      type_doc: "`t:GenServer.name/0`, `t:pid/0` or `nil`",
      type_spec: quote(do: GenServer.name() | pid() | nil),
      default: nil,
      doc: "The name or pid of a `Typsty.Pool` to render in, instead of rendering inside the VM."
    ]
  ]

  @config_only [
    max_concurrent_renders: [
      type: {:custom, __MODULE__, :positive_integer, [@max_count]},
      type_doc: "`t:pos_integer/0`",
      type_spec: quote(do: pos_integer()),
      doc: """
      How many renders may run inside the VM at once, counting renders that timed out and are
      still being cancelled. A render waits for a free slot, within its timeout. This keeps
      renders that keep timing out from piling up in the background. Defaults to the number
      of dirty CPU schedulers (normally the number of CPU cores). See
      `Typsty.running_renders/0`. Renders in a `Typsty.Pool` are limited by its size instead.
      """
    ],
    log_warnings: [
      type: :boolean,
      default: true,
      doc: "Whether to log Typst's warnings with `Logger.warning/1`."
    ],
    packages: [
      type: {:list, :string},
      default: [],
      doc: "The packages `mix typsty.packages.get` fetches when it's run without arguments."
    ]
  ]

  @format [
    line_length: [
      type: {:custom, __MODULE__, :positive_integer, [@max_count]},
      type_doc: "`t:pos_integer/0`",
      type_spec: quote(do: pos_integer()),
      default: 98,
      doc: "The maximum line length."
    ],
    indent: [
      type: {:custom, __MODULE__, :positive_integer, [@max_count]},
      type_doc: "`t:pos_integer/0`",
      type_spec: quote(do: pos_integer()),
      default: 2,
      doc: "The number of spaces to indent by."
    ],
    wrap_text: [type: :boolean, default: false, doc: "Whether to wrap long lines of text in markup."]
  ]

  @formatter [
    typst_line_length: [type: {:custom, __MODULE__, :positive_integer, [@max_count]}],
    typst_indent: [type: {:custom, __MODULE__, :positive_integer, [@max_count]}],
    typst_wrap_text: [type: :boolean]
  ]

  @pool [
    name: [
      type: {:custom, __MODULE__, :name, []},
      type_doc: "`t:GenServer.name/0`",
      type_spec: quote(do: GenServer.name()),
      doc: "The name to register the pool under, to pass as the `:pool` option."
    ],
    size: [
      type: {:custom, __MODULE__, :positive_integer, [@max_count]},
      type_doc: "`t:pos_integer/0`",
      type_spec: quote(do: pos_integer()),
      doc: """
      The number of workers, which is how many renders can run at once. Defaults to the
      number of CPU cores (`System.schedulers_online/0`). A render waits for a free worker,
      within its timeout.
      """
    ],
    memory_limit: [
      type: {:custom, __MODULE__, :memory_limit, []},
      type_doc: "`t:pos_integer/0` or `nil`",
      type_spec: quote(do: pos_integer() | nil),
      default: nil,
      doc: """
      The most memory, in bytes, each worker may use. A render that goes over it fails, and
      its worker is replaced. `nil` is no limit. See [Memory](#module-memory).
      """
    ],
    max_renders: [
      type: {:custom, __MODULE__, :optional_positive_integer, []},
      type_doc: "`t:pos_integer/0` or `nil`",
      type_spec: quote(do: pos_integer() | nil),
      default: nil,
      doc: """
      Replaces each worker after this many renders, which bounds the memory a long-running
      worker holds on to, and gives it a fresh table of file paths (see
      [Files](Typsty.html#module-files)). `nil` keeps workers for as long as they work.
      """
    ]
  ]

  @font_options [:font_paths, :system_fonts, :embedded_fonts]

  @schemas %{
    render: @render,
    config: @config_only,
    format: @format,
    fonts: Keyword.take(@render, @font_options),
    pool: @pool
  }

  # The most memory a worker may be given: a 64-bit worker can't count more
  @max_memory_limit Integer.pow(2, 62)

  # Options given to a function are validated without their defaults, and so is the
  # config, so that the defaults, the config and the options can be merged in that order.
  # The schemas are checked once, when this module compiles.
  without_defaults = fn schema -> Keyword.new(schema, fn {key, spec} -> {key, Keyword.delete(spec, :default)} end) end

  @render_given NimbleOptions.new!(without_defaults.(@render))
  @config_given NimbleOptions.new!(without_defaults.(Keyword.delete(@render, :files) ++ @config_only))
  @fonts_given NimbleOptions.new!(without_defaults.(Keyword.take(@render, @font_options)))
  @format_schema NimbleOptions.new!(@format)
  @formatter_schema NimbleOptions.new!(@formatter)
  @pool_schema NimbleOptions.new!(@pool)

  @render_defaults for {key, spec} <- @render, Keyword.has_key?(spec, :default), do: {key, spec[:default]}
  @config_defaults for {key, spec} <- @config_only, Keyword.has_key?(spec, :default), do: {key, spec[:default]}

  @doc false
  # The options' documentation, for the module docs
  @spec docs(:render | :config | :format | :pool) :: String.t()
  def docs(schema), do: NimbleOptions.docs(Map.fetch!(@schemas, schema))

  @doc false
  # The options' typespec
  @spec typespec(:render | :format | :fonts | :pool) :: Macro.t()
  def typespec(schema), do: NimbleOptions.option_typespec(Map.fetch!(@schemas, schema))

  @doc false
  # The defaults of Typsty.format/2's options, which the formatter plugin shares
  @spec format_defaults() :: keyword()
  def format_defaults, do: for({key, spec} <- @format, do: {key, spec[:default]})

  @doc false
  # The options to render with: the defaults, overridden by the config, overridden by the
  # given options, with the config-only options too
  @spec render!(term()) :: keyword()
  def render!(opts) do
    opts = validate!(opts, @render_given)

    @render_defaults
    |> Keyword.merge(@config_defaults)
    |> Keyword.put(:max_concurrent_renders, :erlang.system_info(:dirty_cpu_schedulers))
    |> Keyword.merge(config!())
    |> Keyword.merge(opts)
  end

  @doc false
  # The font options, for Typsty.font_families/1
  @spec fonts!(term()) :: keyword()
  def fonts!(opts) do
    opts = validate!(opts, @fonts_given)

    @render_defaults
    |> Keyword.merge(config!())
    |> Keyword.merge(opts)
    |> Keyword.take(@font_options)
  end

  @doc false
  @spec format!(term()) :: keyword()
  def format!(opts), do: validate!(opts, @format_schema)

  @doc false
  # The formatter plugin's own options, among the formatter's
  @spec formatter!(keyword()) :: keyword()
  def formatter!(opts), do: opts |> Keyword.take(Keyword.keys(@formatter)) |> validate!(@formatter_schema)

  @doc false
  @spec pool!(term()) :: keyword()
  def pool!(opts), do: validate!(opts, @pool_schema)

  # The application config. Rustler reads Typsty.Native's config (`config :typsty,
  # Typsty.Native, ...`), which is its to check
  defp config! do
    config = :typsty |> Application.get_all_env() |> Keyword.delete(Typsty.Native)

    for {key, _value} <- config, key |> Atom.to_string() |> String.starts_with?("Elixir.") do
      raise ArgumentError,
            "config :typsty, #{inspect(key)} isn't read: Typsty's options go directly under :typsty " <>
              "(config :typsty, ppi: 300), and a Typsty.Pool's options go in its child spec"
    end

    if Keyword.has_key?(config, :files) do
      raise ArgumentError, "the :files option can't be set in the config, only given to a render"
    end

    case NimbleOptions.validate(config, @config_given) do
      {:ok, config} -> config
      {:error, error} -> raise ArgumentError, Exception.message(error) <> " (in the :typsty application config)"
    end
  end

  defp validate!(opts, schema) do
    if not Keyword.keyword?(opts) do
      raise ArgumentError, "the options must be a keyword list, got: #{inspect(opts)}"
    end

    # Like Keyword.get/2, the first of an option given more than once wins, so that defaults
    # can be appended to options: opts ++ [ppi: 300]
    case NimbleOptions.validate(Enum.uniq_by(opts, &elem(&1, 0)), schema) do
      {:ok, opts} -> opts
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  # Custom types, for clearer messages than NimbleOptions' combinations of types give

  @doc false
  def files(files) when is_map(files) or is_list(files) do
    files = Enum.to_list(files)

    case Enum.find_value(files, &file_problem/1) do
      nil -> {:ok, files}
      problem -> {:error, problem}
    end
  end

  def files(other), do: {:error, "expected a map or a list of tuples, got: #{inspect(other, limit: 5)}"}

  defp file_problem({path, contents}) when is_binary(path) and is_binary(contents) do
    if not String.valid?(path), do: "expected paths that are valid UTF-8, got: #{inspect(path)}"
  end

  defp file_problem(other), do: "expected paths (strings) mapped to binaries, got: #{inspect(other, limit: 5)}"

  @doc false
  def optional_path(nil), do: {:ok, nil}

  def optional_path(path) when is_binary(path) do
    if String.valid?(path), do: {:ok, path}, else: {:error, "expected a path that's valid UTF-8, got: #{inspect(path)}"}
  end

  def optional_path(other), do: {:error, "expected a path (a string) or nil, got: #{inspect(other)}"}

  @doc false
  def paths(paths) when is_list(paths) do
    case Enum.reject(paths, &(is_binary(&1) and String.valid?(&1))) do
      [] ->
        {:ok, paths}

      [other | _] ->
        {:error, "expected a list of paths (strings that are valid UTF-8), and #{inspect(other)} isn't one"}
    end
  end

  def paths(other), do: {:error, "expected a list of paths, got: #{inspect(other)}"}

  @doc false
  def positive_number(number, max) when is_number(number) and number > 0 and number <= max, do: {:ok, number}
  def positive_number(other, max), do: {:error, "expected a positive number of at most #{max}, got: #{inspect(other)}"}

  @doc false
  def positive_integer(value, max) when is_integer(value) and value > 0 and value <= max, do: {:ok, value}

  def positive_integer(other, max),
    do: {:error, "expected a positive integer of at most #{max}, got: #{inspect(other)}"}

  @doc false
  def optional_positive_integer(value) when (is_integer(value) and value > 0) or is_nil(value), do: {:ok, value}
  def optional_positive_integer(other), do: {:error, "expected a positive integer or nil, got: #{inspect(other)}"}

  @doc false
  def memory_limit(value) when is_integer(value) and value > @max_memory_limit do
    {:error, "expected a number of bytes of at most #{@max_memory_limit}, or nil, got: #{value}"}
  end

  def memory_limit(value), do: optional_positive_integer(value)

  @doc false
  def timeout(:infinity), do: {:ok, :infinity}
  def timeout(timeout) when is_integer(timeout) and timeout > 0 and timeout <= @max_timeout, do: {:ok, timeout}

  def timeout(other) do
    {:error,
     "expected a positive integer of milliseconds (at most #{@max_timeout}) or :infinity, got: #{inspect(other)}"}
  end

  @doc false
  def pool(nil), do: {:ok, nil}
  def pool(pid) when is_pid(pid), do: {:ok, pid}
  def pool(name), do: with({:error, _} <- name(name), do: {:error, pool_error(name)})

  defp pool_error(other), do: "expected the name or pid of a Typsty.Pool, or nil, got: #{inspect(other)}"

  @doc false
  def name(name) when is_atom(name) and name not in [nil, true, false], do: {:ok, name}
  def name({:global, _name} = name), do: {:ok, name}
  def name({:via, module, _name} = name) when is_atom(module), do: {:ok, name}
  def name(other), do: {:error, "expected an atom, {:global, term} or {:via, module, term}, got: #{inspect(other)}"}
end
