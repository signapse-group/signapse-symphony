defmodule SymphonyElixir.InstructionReferences do
  @moduledoc false

  # shortcut: checks inline Markdown links and ATX headings. Extend if the consumer syntax changes.
  @link ~r/(?<!!)\[([^\]\n]+)\]\((<[^>\n]+>|[^\s)]+)(?:\s+"[^"]*")?\)/
  @heading ~r/^\s{0,3}\#{1,6}\s+(.+?)\s*#*\s*$/
  @fence ~r/^\s*(`{3,}|~{3,})/

  @doc false
  @spec checkout_requirements(Path.t(), Path.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, [{Path.t(), String.t() | nil}]} | {:error, :unsafe_instruction_reference}
  def checkout_requirements(root, workflow, template, rendered, profile_id) do
    authored = MapSet.new(references(template, workflow))

    rendered
    |> references(workflow)
    |> Enum.filter(&MapSet.member?(authored, &1))
    |> Enum.reduce_while({:ok, []}, fn link, {:ok, paths} ->
      case checkout_reference(root, link, profile_id) do
        {:ok, relative, anchor} -> {:cont, {:ok, [{relative, anchor} | paths]}}
        :optional -> {:cont, {:ok, paths}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp checkout_reference(root, {source, target, label}, profile_id) do
    [path | anchors] = String.split(target, "#", parts: 2)
    path = URI.decode(path)

    if not provenance?(label) and checkout_requirement?(path, profile_id),
      do: resolve_reference_path(root, source, path, List.first(anchors)),
      else: :optional
  end

  @doc false
  @spec checkout_anchor(String.t(), String.t() | nil) :: :ok | {:error, :missing_instruction_anchor}
  def checkout_anchor(content, anchor), do: validate_anchor(content, anchor)

  defp checkout_requirement?(path, profile_id) do
    not Regex.match?(~r/\A(?:[A-Za-z][A-Za-z0-9+.-]*:|\/\/)/, path) and
      (Regex.match?(~r{(?:^|/)(?:(?:AGENTS(?:\.override)?|CONTRIBUTING|README)\.md|docs/runbooks/[^/]+\.md|\.agents/skills/[^/]+/SKILL\.md)$}, path) or
         (profile_id == "planning" and String.ends_with?(path, ".md")))
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

  defp provenance?(label), do: String.starts_with?(String.downcase(label), "provenance:")

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
