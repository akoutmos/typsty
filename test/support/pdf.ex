defmodule Typsty.Test.PDF do
  @moduledoc false
  # Reads what tests check in the PDFs Typst writes. Their content streams are compressed,
  # but their objects' dictionaries aren't, so the page tree, the document's info, its
  # links, fonts and outline can be read from the bytes.

  @doc "The number of pages, from the page tree's root."
  def page_count(pdf) do
    [count] = Regex.run(~r"/Type/Pages/Count (\d+)", pdf, capture: :all_but_first)
    String.to_integer(count)
  end

  @doc "Each page's media box (`[x0, y0, x1, y1]`, in points), in the order of the pages."
  def media_boxes(pdf) do
    objects = objects(pdf)
    {_id, pages} = Enum.find(objects, fn {_id, dict} -> dict =~ "/Type/Pages" end)
    [kids] = Regex.run(~r"/Kids\[([^\]]*)\]", pages, capture: :all_but_first)

    for [id] <- Regex.scan(~r"(\d+) 0 R", kids, capture: :all_but_first) do
      [box] = Regex.run(~r"/MediaBox\[([^\]]*)\]", Map.fetch!(objects, String.to_integer(id)), capture: :all_but_first)
      box |> String.split() |> Enum.map(&elem(Float.parse(&1), 0))
    end
  end

  @doc """
  The width and height in pixels of each image the document embeds, leaving out the masks
  that hold images' transparency.
  """
  def images(pdf) do
    images = Regex.scan(~r"(\d+) 0 obj\n<<([^>]*/Subtype/Image[^>]*)>>\nstream", pdf, capture: :all_but_first)

    masks =
      for [_id, dict] <- images, [mask] <- Regex.scan(~r"/SMask (\d+) 0 R", dict, capture: :all_but_first), do: mask

    for [id, dict] <- images, id not in masks do
      [width, height] = Regex.run(~r"/Width (\d+)/Height (\d+)", dict, capture: :all_but_first)
      {String.to_integer(width), String.to_integer(height)}
    end
  end

  @doc "The text of an element of the document's XMP metadata, such as `xmp:CreateDate`, or nil."
  def xmp(pdf, element) do
    case Regex.run(~r"<#{element}>(?:<rdf:\w+><rdf:li[^>]*>)?([^<]*)<", pdf, capture: :all_but_first) do
      [text] -> text
      nil -> nil
    end
  end

  @doc "The PDF version, from the header."
  def version("%PDF-" <> <<version::binary-size(3), _rest::binary>>), do: version

  @doc "The document info dictionary's entries, such as Title and Author, as strings."
  def info(pdf) do
    pdf
    |> objects()
    |> Map.values()
    |> Enum.find("", &(&1 =~ ~r"^/(Title|Author|Creator)[(<]"))
    |> strings()
  end

  @doc "The URIs that the document's links lead to, in order."
  def link_uris(pdf) do
    ~r"/S/URI/URI(?=[(<])"
    |> Regex.split(pdf)
    |> Enum.drop(1)
    |> Enum.map(&(&1 |> string() |> elem(0)))
  end

  @doc "The names of the embedded fonts, without their subset tags, sorted."
  def fonts(pdf) do
    ~r"/FontName/[A-Z]{6}\+([^/\s>]+)"
    |> Regex.scan(pdf, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  The outline (the bookmarks headings make), in order: a list of `{title, children}`.
  """
  def outline(pdf) do
    objects = objects(pdf)

    case Enum.find(objects, fn {_id, dict} -> dict =~ "/Type/Outlines" end) do
      nil -> []
      {_id, root} -> items(ref(root, "First"), objects)
    end
  end

  defp items(nil, _objects), do: []

  defp items(id, objects) do
    dict = Map.fetch!(objects, id)
    [{strings(dict)["Title"], items(ref(dict, "First"), objects)} | items(ref(dict, "Next"), objects)]
  end

  defp ref(dict, key) do
    case Regex.run(~r"/#{key} (\d+) 0 R", dict, capture: :all_but_first) do
      [id] -> String.to_integer(id)
      nil -> nil
    end
  end

  # The objects that are dictionaries, by number (streams aside)
  defp objects(pdf) do
    ~r"(?:^|\n)(\d+) 0 obj\n<<((?:(?!endobj).)*?)>>\nendobj"s
    |> Regex.scan(pdf, capture: :all_but_first)
    |> Map.new(fn [id, dict] -> {String.to_integer(id), dict} end)
  end

  # A dictionary's string entries
  defp strings(dict) do
    ~r"/(\w+)(?=[(<][^<])"
    |> Regex.split(dict, include_captures: true)
    |> Enum.drop(1)
    |> Enum.chunk_every(2)
    |> Enum.flat_map(fn
      ["/" <> key, rest] ->
        case string(rest) do
          {value, _rest} when is_binary(value) -> [{key, value}]
          :error -> []
        end

      _other ->
        []
    end)
    |> Map.new()
  end

  # A PDF string at the start of the binary: a literal string, whose parentheses can nest
  # and be escaped, or a hex string. Strings that start with a byte order mark are UTF-16BE
  defp string("(" <> rest), do: literal(rest, 0, [])
  defp string("<" <> rest), do: hex(rest)
  defp string(_other), do: :error

  defp literal(")" <> rest, 0, acc), do: {decode(IO.iodata_to_binary(Enum.reverse(acc))), rest}
  defp literal(")" <> rest, depth, acc), do: literal(rest, depth - 1, [")" | acc])
  defp literal("(" <> rest, depth, acc), do: literal(rest, depth + 1, ["(" | acc])
  defp literal("\\n" <> rest, depth, acc), do: literal(rest, depth, ["\n" | acc])
  defp literal("\\r" <> rest, depth, acc), do: literal(rest, depth, ["\r" | acc])
  defp literal("\\t" <> rest, depth, acc), do: literal(rest, depth, ["\t" | acc])
  defp literal(<<"\\", char, rest::binary>>, depth, acc), do: literal(rest, depth, [char | acc])
  defp literal(<<char, rest::binary>>, depth, acc), do: literal(rest, depth, [char | acc])

  defp hex(rest) do
    [digits, rest] = String.split(rest, ">", parts: 2)
    {digits |> String.replace(~r"\s", "") |> Base.decode16!(case: :mixed) |> decode(), rest}
  end

  defp decode(<<0xFE, 0xFF, utf16::binary>>), do: :unicode.characters_to_binary(utf16, {:utf16, :big})
  defp decode(bytes), do: bytes
end
