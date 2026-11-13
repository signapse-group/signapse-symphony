defmodule SymphonyElixir.BurritoLinuxRuntime do
  @moduledoc false

  @loader_sha256 "71c35316aff45bbfd243d8eb9bfc4a58b6eb97cee09514cd2030e145b68107fb"

  @spec execute(map()) :: map()
  def execute(%{target: %{alias: :linux_x86_64, erts_source: {:local, _}} = target} = context) do
    # Burrito only embeds its musl loader automatically for precompiled targets.
    context =
      context
      |> Map.put(:target, %{target | erts_source: {:precompiled, []}})
      |> Burrito.Steps.Fetch.FetchMusl.execute()

    digest = :crypto.hash(:sha256, File.read!(Path.join(context.self_dir, "src/musl-runtime.so")))

    unless Base.encode16(digest, case: :lower) == @loader_sha256 do
      raise "Unexpected Burrito Linux x86_64 musl loader"
    end

    %{context | target: target}
  end

  def execute(%{target: %{alias: :linux_x86_64, erts_source: {:local_unpacked, [path: path]}}} = context) do
    if System.get_env("SYMPHONY_BURRITO_X86_64_ERTS") do
      otp_release = :erlang.system_info(:otp_release) |> List.to_string()
      version_file = Path.join(["releases", otp_release, "OTP_VERSION"])
      [target_version] = path |> Path.join("otp*/#{version_file}") |> Path.wildcard()
      version = File.read!(target_version)

      unless String.trim(version) == String.trim(File.read!(Path.join(List.to_string(:code.root_dir()), version_file))) do
        raise "Burrito target OTP and build OTP versions must match"
      end

      File.write!(Path.join(context.work_dir, "OTP_VERSION"), version)
    end

    context
  end

  def execute(context), do: context
end

defmodule SymphonyElixir.MixProject do
  use Mix.Project

  def project do
    [
      app: :symphony_elixir,
      version: "0.0.3",
      elixir: "~> 1.19",
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      test_coverage: [
        summary: [
          threshold: 100
        ],
        ignore_modules: [
          SymphonyElixir.Asana.Client,
          SymphonyElixir.Config,
          SymphonyElixir.GitHub.Client,
          SymphonyElixir.GitLab.Client,
          SymphonyElixir.Jira.Client,
          SymphonyElixir.Linear.Client,
          SymphonyElixir.SpecsCheck,
          SymphonyElixir.Orchestrator,
          SymphonyElixir.Orchestrator.State,
          # Stateful runtime boundaries are verified through OTP integration tests.
          SymphonyElixir.RuntimeControl,
          # Their failure/recovery behavior is exercised with real OTP processes and SQLite.
          SymphonyElixir.AssignmentOwners,
          SymphonyElixir.Profile,
          SymphonyElixir.WorkflowStore,
          SymphonyElixir.AgentRunner,
          SymphonyElixir.Application,
          SymphonyElixir.CLI,
          SymphonyElixir.Codex.AppServer,
          SymphonyElixir.Codex.SessionProcess,
          SymphonyElixir.Codex.DynamicTool,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard,
          SymphonyElixir.LogFile,
          SymphonyElixir.Workspace,
          SymphonyElixirWeb.DashboardLive,
          SymphonyElixirWeb.Endpoint,
          SymphonyElixirWeb.ErrorHTML,
          SymphonyElixirWeb.ErrorJSON,
          SymphonyElixirWeb.Layouts,
          SymphonyElixirWeb.ObservabilityApiController,
          SymphonyElixirWeb.Presenter,
          SymphonyElixirWeb.ProfileObservability,
          SymphonyElixirWeb.StaticAssetController,
          SymphonyElixirWeb.StaticAssets,
          SymphonyElixirWeb.Router,
          SymphonyElixirWeb.Router.Helpers
        ]
      ],
      test_ignore_filters: [
        "test/support/snapshot_support.exs",
        "test/support/test_support.exs"
      ],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      escript: escript(),
      releases: releases(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {SymphonyElixir.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix, "~> 1.8.0"},
      {:phoenix_html, "~> 4.2"},
      {:phoenix_live_view, "~> 1.1.0"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:yaml_elixir, "~> 2.12"},
      {:solid, "~> 1.2"},
      {:ecto, "~> 3.13"},
      {:exqlite, "~> 0.30.1"},
      {:burrito, "~> 1.5", only: :prod, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      build: ["escript.build"],
      lint: ["specs.check", "credo --strict"]
    ]
  end

  defp escript do
    [
      app: nil,
      main_module: SymphonyElixir.CLI,
      name: "symphony",
      path: "bin/symphony"
    ]
  end

  defp releases do
    [
      symphony: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          extra_steps: [fetch: [pre: [SymphonyElixir.BurritoLinuxRuntime]], patch: [post: [SymphonyElixir.BurritoLinuxRuntime]]],
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64, custom_erts: System.get_env("SYMPHONY_BURRITO_X86_64_ERTS")]
          ]
        ]
      ]
    ]
  end
end
