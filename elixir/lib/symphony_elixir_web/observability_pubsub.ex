defmodule SymphonyElixirWeb.ObservabilityPubSub do
  @moduledoc """
  PubSub helpers for observability dashboard updates.
  """

  @pubsub SymphonyElixir.PubSub
  @topic "observability:dashboard"
  @update_message :observability_updated
  @profiles_topic "observability:profiles"

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @spec subscribe_profiles() :: :ok | {:error, term()}
  def subscribe_profiles, do: Phoenix.PubSub.subscribe(@pubsub, @profiles_topic)

  @spec broadcast_update(String.t()) :: :ok
  def broadcast_update(profile_id), do: broadcast(@profiles_topic, {@update_message, profile_id})

  @spec broadcast_update() :: :ok
  def broadcast_update, do: broadcast(@topic, @update_message)

  defp broadcast(topic, message) do
    case Process.whereis(@pubsub) do
      pid when is_pid(pid) ->
        Phoenix.PubSub.broadcast(@pubsub, topic, message)

      _ ->
        :ok
    end
  end
end
