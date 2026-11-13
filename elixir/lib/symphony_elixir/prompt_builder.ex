defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.{Config, Instructions, Workflow}
  alias SymphonyElixir.Tracker.Issue

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template = Workflow.current() |> prompt_template!() |> parse_template!()
    render(template, issue, Keyword.get(opts, :attempt), %{})
  end

  @spec build_prompt(Issue.t(), non_neg_integer() | nil, Instructions.pin()) :: String.t()
  def build_prompt(issue, attempt, pin) do
    """
    Symphony profile #{pin.profile_id} uses instructions revision #{pin.revision}.
    Read AGENTS.md and the required phase instructions from #{pin.root}.
    Resolve instructions links in the following workflow relative to #{pin.workflow_path}.
    The issue workspace is the working directory for task code and outputs.

    """ <> render_instructions(issue, attempt, pin)
  end

  @doc false
  @spec render_instructions(Issue.t(), non_neg_integer() | nil, Instructions.prompt_pin()) :: String.t()
  def render_instructions(issue, attempt, pin) do
    template = parse_template!(pin.workflow.prompt_template)

    render(template, issue, attempt, %{
      "profile" => %{"id" => pin.profile_id},
      "instructions" => %{"root" => pin.root, "revision" => pin.revision}
    })
  end

  defp render(template, issue, attempt, context) do
    template
    |> Solid.render!(
      Map.merge(context, %{"attempt" => attempt, "issue" => issue |> Map.from_struct() |> to_solid_map()}),
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
