defmodule FireBird.MockWAL do
  @moduledoc false
  @behaviour FireBird.WAL

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  @doc "Starts the mock WAL agent."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{entries: [], fail_appends: false} end, name: name)
  end

  @doc "Returns all appended entries, oldest first (the WAL contract)."
  @spec entries(GenServer.server()) :: [term()]
  def entries(name \\ __MODULE__) do
    Agent.get(name, & &1.entries)
  end

  @doc "When enabled, append/2 fails with {:error, :disk_full}."
  @spec set_fail_appends(GenServer.server(), boolean()) :: :ok
  def set_fail_appends(name \\ __MODULE__, flag) do
    failure = if flag, do: {:error, :disk_full}, else: false
    Agent.update(name, &Map.put(&1, :fail_appends, failure))
  end

  @doc "Makes append/2 return {:error, reason} without recording an entry."
  @spec set_append_error(GenServer.server(), term()) :: :ok
  def set_append_error(name \\ __MODULE__, reason) do
    Agent.update(name, &Map.put(&1, :fail_appends, {:error, reason}))
  end

  @impl FireBird.WAL
  def append(config, entry) do
    name = resolve_name(config)

    case Agent.get(name, & &1.fail_appends) do
      false ->
        Agent.update(name, &%{&1 | entries: &1.entries ++ [entry]})
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl FireBird.WAL
  def recover(config) do
    {:ok, Agent.get(resolve_name(config), & &1.entries)}
  end

  defp resolve_name(name) when is_atom(name), do: name
  defp resolve_name(_other), do: __MODULE__
end
