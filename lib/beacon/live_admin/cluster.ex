defmodule Beacon.LiveAdmin.Cluster do
  @ets_table :beacon_live_admin_sites

  @doc """
  Scans the cluster to find running sites and store them in a ETS table.

    ## Examples

        iex> Beacon.LiveAdmin.Cluster.discover_sites()
        %{
          my_site: [:"node_a@region_a", :"node_b@region_b"], my_blog: [:"node_b@region_b"],
          my_blog: [:"node_a@region_a"]
        }

  """
  def discover_sites do
    # add or remove nodes from ets state when nodes changes
    # instead of recreating everything
    :ets.delete_all_objects(@ets_table)

    nodes()
    |> Map.new(fn node ->
      try do
        sites = :erpc.call(node, Beacon.Registry, :running_sites, [], :timer.seconds(10))
        {node, sites}
      rescue
        _exception ->
          {node, []}
      end
    end)
    |> group_sites()
    |> Map.new(fn site ->
      true = :ets.insert(@ets_table, site)
      site
    end)
  end

  @doc false
  def nodes do
    [Node.self()] ++ Node.list()
  end

  @doc false
  def group_sites(mapping) do
    Enum.reduce(mapping, %{}, fn {node, sites}, acc ->
      new = :maps.from_list(:lists.map(&{&1, [node]}, sites))

      Map.merge(acc, new, fn _k, v1, v2 ->
        Enum.dedup(v1 ++ v2)
      end)
    end)
  end

  def running_sites do
    @ets_table
    |> :ets.match({:"$1", :_})
    |> List.flatten()
  end

  @doc """
  Calls a function for a running `site` in the cluster.

  It will call the function in only one of the available nodes to avoid double execution of `fun`.

    ## Examples

        iex> Beacon.LiveAdmin.Cluster.call(:my_site, Beacon, :reload_site, [:my_site])
        :ok

  """
  def call(site, module, fun, args)
      when is_atom(site) and is_atom(module) and is_atom(fun) and is_list(args) do
    case find_node(site) do
      nil -> {:error, :nodedown}
      node -> :erpc.call(node, module, fun, args)
    end
  rescue
    exception -> exception
  end

  if Code.ensure_loaded?(Mix.Project) and Mix.env() == :test do
    defp find_node(site) when is_atom(site) do
      case :ets.match(@ets_table, {site, :"$1"}) do
        [[nodes]] -> List.first(nodes)
        _ -> nil
      end
    end
  else
    defp find_node(site) when is_atom(site) do
      case :ets.match(@ets_table, {site, :"$1"}) do
        # TODO: load balance and retry
        [[nodes]] -> Enum.random(nodes)
        _ -> nil
      end
    end
  end
end