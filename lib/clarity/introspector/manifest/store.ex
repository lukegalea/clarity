defmodule Clarity.Introspector.Manifest.Store do
  @moduledoc false

  # Loads and caches Spark/Ash semantic manifest documents
  # (`semantic-manifest-v0`).
  #
  # Documents are read from the paths returned by `manifest_paths/0` and cached
  # in an ETS table keyed by path + file stat, so a changed manifest file is
  # picked up without restarting, while repeated introspector calls (one per
  # module vertex) hit the cache.
  #
  # Everything here is deliberately failure-tolerant: a missing, unreadable, or
  # malformed manifest degrades to "no manifest" with a single logged warning
  # per file version. A manifest must never crash the graph.

  require Logger

  @table :clarity_semantic_manifest_store

  @type document() :: %{
          required(String.t()) => term()
        }

  @doc """
  Returns the manifest document declaring `module_string` (e.g.
  `"Demo.Accounts.User"`), or `:not_found` when no readable manifest declares
  it.
  """
  @spec lookup(String.t()) :: {:ok, document()} | :not_found
  def lookup(module_string) when is_binary(module_string) do
    ensure_table()

    Enum.find_value(manifest_paths(), :not_found, fn path ->
      case load(path) do
        {:ok, %{"module" => ^module_string} = document} -> {:ok, document}
        _other -> nil
      end
    end)
  end

  @doc """
  The configured manifest paths.

  Supports both a global configuration on the `:clarity` application and a
  per-application list:

      config :clarity, :semantic_manifest, path: "priv/semantic/manifest.json"
      config :clarity, :semantic_manifest, paths: ["priv/semantic/a.json", ...]
      config :clarity, :semantic_manifest, "priv/semantic/manifest.json"

      # Per-application registration, collected across all loaded apps:
      config :my_app, :clarity_semantic_manifests, ["priv/semantic/manifest.json"]
  """
  @spec manifest_paths() :: [String.t()]
  def manifest_paths do
    global = global_paths()
    per_app = per_app_paths()

    Enum.uniq(global ++ per_app)
  end

  @spec global_paths() :: [String.t()]
  defp global_paths do
    case Application.get_env(:clarity, :semantic_manifest) do
      nil -> []
      value -> normalize_config(value)
    end
  end

  @spec per_app_paths() :: [String.t()]
  defp per_app_paths do
    Application.loaded_applications()
    |> Enum.map(&elem(&1, 0))
    |> Enum.flat_map(&Application.get_env(&1, :clarity_semantic_manifests, []))
    |> Enum.filter(&is_binary/1)
  end

  @spec normalize_config(term()) :: [String.t()]
  defp normalize_config(path) when is_binary(path), do: [path]

  defp normalize_config(paths) when is_list(paths) do
    if Keyword.keyword?(paths) do
      List.wrap(Keyword.get(paths, :path)) ++ List.wrap(Keyword.get(paths, :paths))
    else
      Enum.filter(paths, &is_binary/1)
    end
  end

  defp normalize_config(_other), do: []

  # Loading and caching

  @spec load(String.t()) :: {:ok, document()} | {:error, term()}
  def load(path) do
    ensure_table()

    key = cache_key(path)

    case :ets.lookup(@table, key) do
      [{^key, result}] ->
        result

      [] ->
        result = parse(path)
        :ets.insert(@table, {key, result})
        result
    end
  end

  # The stat (mtime + size) is part of the cache key, so editing a manifest
  # invalidates exactly that file's cached parse.
  @spec cache_key(String.t()) :: {String.t(), :missing | {term(), non_neg_integer()}}
  defp cache_key(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mtime: mtime, size: size}} -> {path, {mtime, size}}
      {:error, _reason} -> {path, :missing}
    end
  end

  @spec parse(String.t()) :: {:ok, document()} | {:error, term()}
  defp parse(path) do
    case File.read(path) do
      {:ok, body} ->
        decode(path, body)

      {:error, reason} ->
        warn_once(path, "could not be read (#{inspect(reason)})")
        {:error, reason}
    end
  end

  @spec decode(String.t(), binary()) :: {:ok, document()} | {:error, term()}
  defp decode(path, body) do
    case Jason.decode(body) do
      {:ok, %{"module" => module, "symbols" => symbols} = document}
      when is_binary(module) and is_list(symbols) ->
        {:ok, document}

      {:ok, %{"module" => module}} when not is_binary(module) ->
        warn_once(path, "is malformed: \"module\" must be a string")
        {:error, :malformed}

      {:ok, %{"symbols" => symbols}} when not is_list(symbols) ->
        warn_once(path, "is malformed: \"symbols\" must be a list")
        {:error, :malformed}

      {:ok, _other} ->
        warn_once(path, ~s(is malformed: missing "module" or "symbols"))
        {:error, :malformed}

      {:error, reason} ->
        warn_once(path, "is not valid JSON (#{Exception.message(reason)})")
        {:error, reason}
    end
  end

  # The warning fires on cache miss only, so each file version warns once
  # no matter how many module vertices trigger the lookup.
  @spec warn_once(String.t(), String.t()) :: :ok
  defp warn_once(path, reason) do
    Logger.warning("Clarity semantic manifest at #{path} #{reason}; ignoring it")
  end

  @spec ensure_table() :: :ok
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> create_table()
      _table -> :ok
    end
  rescue
    ArgumentError -> create_table()
  end

  @spec create_table() :: :ok
  defp create_table do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
  rescue
    ArgumentError -> :ok
  end
end
