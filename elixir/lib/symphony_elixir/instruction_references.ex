defmodule SymphonyElixir.InstructionReferences do
  @moduledoc false

  alias SymphonyElixir.PathSafety

  # shortcut: checks inline Markdown links and ATX headings. Extend if the consumer syntax changes.
  @link ~r/(?<!!)\[([^\]\n]+)\]\((<[^>\n]+>|[^\s)]+)(?:\s+"[^"]*")?\)/
  @heading ~r/^\s{0,3}\#{1,6}\s+(.+?)\s*#*\s*$/
  @fence ~r/^\s*(`{3,}|~{3,})/

  @spec read_regular(Path.t(), Path.t()) :: {:ok, binary()} | {:error, atom()}
  def read_regular(root, relative) do
    path = Path.expand(relative, root)

    with true <- inside?(root, path),
         {:ok, ^path} <- PathSafety.canonicalize(path),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      _ -> {:error, :missing_or_unsafe_instruction_file}
    end
  end

  @doc false
  @spec checkout_requirements(Path.t(), Path.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, [{Path.t(), String.t() | nil}]} | {:error, :unsafe_instruction_reference}
  def checkout_requirements(root, workflow, template, rendered, profile_id) do
    authored = MapSet.new(references(template, workflow))

    rendered
    |> references(workflow)
    |> Enum.filter(&MapSet.member?(authored, &1))
    |> Enum.reduce_while({:ok, []}, fn {source, target, label}, {:ok, paths} ->
      [path | anchors] = String.split(target, "#", parts: 2)
      path = URI.decode(path)

      if not provenance?(label) and checkout_requirement?(path, profile_id) do
        case resolve_reference_path(root, source, path, List.first(anchors)) do
          {:ok, relative, anchor} -> {:cont, {:ok, [{relative, anchor} | paths]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, {:ok, paths}}
      end
    end)
  end

  @doc false
  @spec checkout_anchor(String.t(), String.t() | nil) :: :ok | {:error, :missing_instruction_anchor}
  def checkout_anchor(content, anchor), do: validate_anchor(content, anchor)

  defp checkout_requirement?(path, profile_id) do
    not Regex.match?(~r/\A(?:[A-Za-z][A-Za-z0-9+.-]*:|\/\/)/, path) and
      (Regex.match?(~r{(?:^|/)(?:(?:AGENTS(?:\.override)?|CONTRIBUTING|README)\.md|docs/runbooks/[^/]+\.md|\.agents/skills/[^/]+/SKILL\.md)$}, path) or
         (profile_id == "planning" and String.ends_with?(path, ".md")))
  end

  @spec collect(Path.t(), Path.t(), [String.t()], [String.t()], (String.t() -> {:ok, binary()} | {:error, atom()})) ::
          {:ok, %{String.t() => binary()}} | {:error, atom()}
  def collect(root, workflow, required, rendered_prompts, read) do
    references = Enum.flat_map(rendered_prompts, &references(&1, workflow))
    paths = Enum.map([workflow | required], &{workflow, &1, :root})
    visit(paths ++ references, root, workflow, read, %{})
  end

  defp visit([], _root, _workflow, _read, files), do: {:ok, files}

  defp visit([{from, target, label} | rest], root, workflow, read, files) do
    case resolve(root, from, target, label) do
      :external ->
        visit(rest, root, workflow, read, files)

      {:ok, path, anchor} ->
        with {:ok, content, linked} <- load(path, files, workflow, read),
             :ok <- validate_anchor(content, anchor) do
          visit(linked ++ rest, root, workflow, read, Map.put(files, path, content))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load(path, files, workflow, read) do
    case Map.fetch(files, path) do
      {:ok, content} ->
        {:ok, content, []}

      :error ->
        load_new(path, workflow, read)
    end
  end

  defp load_new(path, workflow, read) do
    with {:ok, content} <- read.(path) do
      read_markdown(path, workflow, content)
    end
  end

  defp read_markdown(path, workflow, content) do
    cond do
      path == workflow or not markdown?(path) -> {:ok, content, []}
      String.valid?(content) -> {:ok, content, references(content, path)}
      true -> {:error, :invalid_instruction_encoding}
    end
  end

  defp references(markdown, source) do
    markdown
    |> prose()
    |> Enum.flat_map(fn line ->
      for [label, target] <- Regex.scan(@link, line, capture: :all_but_first) do
        {source, target |> String.trim_leading("<") |> String.trim_trailing(">"), label}
      end
    end)
  end

  defp resolve(root, _source, path, :root) do
    if Path.type(path) == :relative do
      resolve_local(root, root, path, nil)
    else
      {:error, :unsafe_instruction_reference}
    end
  end

  defp resolve(root, source, target, label) do
    cond do
      provenance?(label) -> :external
      Regex.match?(~r/\A(?:[A-Za-z][A-Za-z0-9+.-]*:|\/\/)/, target) -> resolve_external(target)
      true -> resolve_local_link(root, source, target)
    end
  end

  defp provenance?(label), do: String.starts_with?(String.downcase(label), "provenance:")

  defp resolve_local_link(root, source, target) do
    [path | anchors] = String.split(target, "#", parts: 2)
    resolve_reference_path(root, source, URI.decode(path), List.first(anchors))
  end

  defp resolve_external(target) do
    case URI.new(target) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in ["http", "https"] and is_binary(host) ->
        if instruction_url?(uri), do: {:error, :remote_instruction_reference}, else: :external

      {:ok, %URI{scheme: "mailto"}} ->
        :external

      _ ->
        {:error, :unsafe_instruction_reference}
    end
  end

  defp resolve_reference_path(root, source, "", anchor), do: resolve_local(root, root, source, anchor)

  defp resolve_reference_path(root, source, path, anchor) do
    resolve_local(root, Path.dirname(Path.join(root, source)), path, anchor)
  end

  defp resolve_local(root, base, path, anchor) do
    if valid_path?(path) do
      absolute = Path.expand(path, base)

      if inside?(root, absolute) do
        {:ok, Path.relative_to(absolute, root), anchor}
      else
        {:error, :unsafe_instruction_reference}
      end
    else
      {:error, :unsafe_instruction_reference}
    end
  end

  defp inside?(root, path), do: path != root and List.starts_with?(Path.split(path), Path.split(root))

  defp valid_path?(path) do
    String.valid?(path) and not String.contains?(path, [<<0>>, "\r", "\n", "\\"])
  end

  defp instruction_url?(%URI{host: host, path: path}) do
    case String.downcase(host) do
      "raw.githubusercontent.com" -> true
      "github.com" -> Regex.match?(~r{/(?:blob|tree|raw)/}, path || "")
      _ -> false
    end
  end

  defp validate_anchor(_content, anchor) when anchor in [nil, ""], do: :ok

  defp validate_anchor(content, anchor) do
    if String.valid?(content) and MapSet.member?(anchors(content), URI.decode(anchor)) do
      :ok
    else
      {:error, :missing_instruction_anchor}
    end
  end

  defp anchors(markdown) do
    markdown
    |> prose()
    |> Enum.reduce({MapSet.new(), %{}}, &add_anchor/2)
    |> elem(0)
  end

  defp add_anchor(line, {anchors, counts} = current) do
    case Regex.run(@heading, line, capture: :all_but_first) do
      [heading] ->
        base = slug(heading)
        count = Map.get(counts, base, 0)
        anchor = if count == 0, do: base, else: "#{base}-#{count}"
        {MapSet.put(anchors, anchor), Map.put(counts, base, count + 1)}

      nil ->
        current
    end
  end

  defp slug(heading) do
    heading
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}_\-\s]/u, "")
    |> String.replace(~r/\s/u, "-")
  end

  defp markdown?(path), do: String.downcase(Path.extname(path)) == ".md"

  defp prose(content) do
    {lines, _fence} =
      content
      |> String.split(~r/\R/u)
      |> Enum.map_reduce(nil, &prose_line/2)

    lines
  end

  defp prose_line(line, fence) do
    case Regex.run(@fence, line, capture: :all_but_first) do
      [marker] when is_nil(fence) -> {"", marker}
      [marker] -> {"", if(String.starts_with?(marker, fence), do: nil, else: fence)}
      nil -> {if(is_nil(fence), do: line, else: ""), fence}
    end
  end
end
