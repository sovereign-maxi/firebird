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
    Agent.start_link(fn -> [] end, name: name)
  end

  @doc "Returns all appended entries."
  @spec entries(GenServer.server()) :: [term()]
  def entries(name \\ __MODULE__) do
    Agent.get(name, & &1)
  end

  @impl FireBird.WAL
  def append(config, entry) do
    Agent.update(resolve_name(config), &[entry | &1])
    :ok
  end

  @impl FireBird.WAL
  def recover(config) do
    {:ok, Agent.get(resolve_name(config), & &1)}
  end

  defp resolve_name(name) when is_atom(name), do: name
  defp resolve_name(_other), do: __MODULE__
end
