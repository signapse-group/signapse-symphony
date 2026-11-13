defmodule SymphonyElixir.AgentRuntimeSupervisor do
  @moduledoc """
  Supervises the scheduler authority together with its agent tasks.
  """

  use Supervisor
  alias SymphonyElixir.{Orchestrator, Profile, RuntimeControl}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = if opts[:profile_id], do: {__MODULE__, opts[:profile_id]}, else: __MODULE__
    %{id: id, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = if opts[:profile_id], do: Profile.via(opts[:profile_id], :runtime_supervisor), else: Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init([{:profile_id, id} | _] = opts) do
    control = Profile.via(id, :runtime_control)
    scheduler_opts = [scheduler_children(id, opts), [strategy: :one_for_all]]

    children = [
      {RuntimeControl, name: control, profile_id: id},
      %{id: :profile_scheduler, start: {Supervisor, :start_link, scheduler_opts}, type: :supervisor}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def init(opts) do
    task_supervisor_name =
      Keyword.get(opts, :task_supervisor_name, SymphonyElixir.TaskSupervisor)

    orchestrator_name = Keyword.get(opts, :orchestrator_name, SymphonyElixir.Orchestrator)

    children = [
      Supervisor.child_spec(
        {Task.Supervisor, name: task_supervisor_name},
        id: task_supervisor_name
      ),
      Supervisor.child_spec(
        {Orchestrator, name: orchestrator_name, task_supervisor: task_supervisor_name},
        id: orchestrator_name
      )
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  defp scheduler_children(id, opts) do
    task_supervisor = Profile.via(id, :task_supervisor)

    [
      {Task.Supervisor, name: task_supervisor},
      {Orchestrator, [name: Profile.via(id, :orchestrator), task_supervisor: task_supervisor, profile_id: id] ++ Keyword.take(opts, [:instructions])}
    ]
  end
end
