defmodule Clarity.Introspector.Manifest do
  @moduledoc """
  Imports Spark/Ash semantic manifest documents (`semantic-manifest-v0`) into
  the graph.

  A semantic manifest is a portable JSON description of one DSL module's
  declarative surface, carrying what live introspection cannot: source spans on
  every declaration, stable structural symbol ids, and provenance chains
  telling you *which* `use` macro or transformer put a piece of DSL there.

  This introspector is complementary to the built-in introspectors: it does not
  re-derive the runtime surface from loaded modules. It only runs when a
  manifest is configured, and adds to the graph:

  - a `Clarity.Vertex.Manifest.Symbol` vertex per manifest symbol, with source
    locations built from the manifest spans, and
  - edges from the manifest's `relations` (e.g. `generated_from` and
    `implements_action` edges from generated code-interface functions back to
    the DSL actions they declare), plus provenance edges from each symbol's
    provenance chain to the module that injected it.

  ## Configuration

  Either a global configuration on the `:clarity` application, or a
  per-application list:

      config :clarity, :semantic_manifest, path: "priv/semantic/manifest.json"
      config :clarity, :semantic_manifest, paths: ["priv/semantic/a.json"]

      # Per-application registration, collected across all loaded apps:
      config :my_app, :clarity_semantic_manifests, ["priv/semantic/manifest.json"]

  With no manifest configured — or with a missing, unreadable, or malformed one
  — the introspector is a no-op and never crashes the graph.
  """

  @behaviour Clarity.Introspector

  alias Clarity.Graph
  alias Clarity.Introspector.Manifest.Store
  alias Clarity.Vertex
  alias Clarity.Vertex.Manifest.Symbol, as: SymbolVertex
  alias Clarity.Vertex.Module
  alias Clarity.Vertex.Util

  # The ten symbol kinds defined by semantic-manifest-v0 §4.2. Per §6.2,
  # consumers must skip kinds they do not recognise.
  @known_symbol_kinds [
    "resource",
    "attribute",
    "action",
    "argument",
    "relationship",
    "calculation",
    "aggregate",
    "policy",
    "code_interface_function",
    "section"
  ]

  # Relation kinds from semantic-manifest-v0 §4.7. Known kinds map to edge
  # label atoms; unknown kinds degrade to their string form (never an atom
  # created from manifest data).
  @relation_labels %{
    "contains" => :contains,
    "generated_from" => :generated_from,
    "transformed_from" => :transformed_from,
    "added_by_extension" => :added_by_extension,
    "accepts_input" => :accepts_input,
    "returns" => :returns,
    "references_type" => :references_type,
    "references_named_type" => :references_named_type,
    "references_resource" => :references_resource,
    "guarded_by" => :guarded_by,
    "implements_action" => :implements_action,
    "joins_through" => :joins_through
  }

  # Provenance stages that point at an injecting module produce edges to that
  # module's vertex — this is the "which use macro / transformer put this
  # here" answer the manifest exists for. Stages whose span points at the
  # symbol's own declaration (`declared`, `fragment`, `option_default`,
  # `auto_set`, `generated_code`) produce no edge.
  @provenance_labels %{
    "macro_injected" => :macro_injected_by,
    "transformer_added" => :transformed_from,
    "extension_patch" => :added_by_extension
  }

  @impl Clarity.Introspector
  def source_vertex_types, do: [Module]

  @impl Clarity.Introspector
  def introspect_vertex(%Module{module: module} = module_vertex, graph) do
    case Store.lookup(inspect(module)) do
      {:ok, document} -> {:ok, entries(module_vertex, document, graph)}
      :not_found -> {:ok, []}
    end
  end

  def introspect_vertex(_vertex, _graph), do: {:ok, []}

  # Entry building

  @spec entries(Module.t(), Store.document(), Graph.t()) :: [Clarity.Introspector.entry()]
  defp entries(module_vertex, document, graph) do
    symbol_vertices = symbol_vertices(document)
    vertices_by_id = Map.new(symbol_vertices, fn vertex -> {vertex.symbol_id, vertex} end)

    vertex_entries = Enum.map(symbol_vertices, &{:vertex, &1})

    attach_entries =
      Enum.map(symbol_vertices, fn vertex ->
        {:edge, module_vertex, vertex, :manifest_symbol}
      end)

    relation_entries = relation_entries(document, vertices_by_id, graph)
    provenance_entries = provenance_entries(symbol_vertices, graph)

    vertex_entries ++ attach_entries ++ relation_entries ++ provenance_entries
  end

  @spec symbol_vertices(Store.document()) :: [SymbolVertex.t()]
  defp symbol_vertices(document) do
    module = Map.get(document, "module", "")

    document
    |> Map.get("symbols", [])
    |> Enum.flat_map(fn
      %{"id" => id, "kind" => kind} = symbol
      when is_binary(id) and is_binary(kind) and kind in @known_symbol_kinds ->
        [
          %SymbolVertex{
            manifest_module: module,
            symbol_id: id,
            kind: kind,
            name: Map.get(symbol, "name"),
            span: Map.get(symbol, "span"),
            provenance: provenance_steps(symbol),
            symbol: symbol
          }
        ]

      _symbol ->
        []
    end)
  end

  @spec provenance_steps(map()) :: [map()]
  defp provenance_steps(symbol) do
    case Map.get(symbol, "provenance") do
      steps when is_list(steps) -> Enum.filter(steps, &is_map/1)
      _ -> []
    end
  end

  # Edges from the manifest's top-level `relations`. Both endpoints must be
  # resolvable — a relation whose `to` is a module reference for which no
  # vertex exists in the graph is skipped silently: manifest data must never
  # block the introspection pipeline.
  @spec relation_entries(Store.document(), %{String.t() => SymbolVertex.t()}, Graph.t()) :: [
          Clarity.Introspector.entry()
        ]
  defp relation_entries(document, vertices_by_id, graph) do
    document
    |> Map.get("relations", [])
    |> Enum.flat_map(fn
      %{"from" => from, "to" => to, "kind" => kind} = relation
      when is_binary(from) and is_binary(to) and is_map_key(vertices_by_id, from) ->
        with {:ok, from_vertex} <- Map.fetch(vertices_by_id, from),
             {:ok, to_vertex} <- resolve_target(to, vertices_by_id, graph) do
          [{:edge, from_vertex, to_vertex, relation_label(kind, relation)}]
        else
          _error -> []
        end

      _relation ->
        []
    end)
  end

  @spec relation_label(term(), map()) :: atom() | String.t()
  # A relation kind unknown to v0 stays a string label (creating atoms from
  # manifest data is forbidden by the manifest's own rules, RFC §8).
  defp relation_label(kind, _relation) when is_binary(kind),
    do: Map.get(@relation_labels, kind, kind)

  defp relation_label(kind, _relation), do: kind

  # Manifest symbols carry provenance chains (oldest step first). A step whose
  # `by` names a module with a vertex in the graph yields an edge from the
  # symbol to that module's vertex, labelled by the provenance stage.
  @spec provenance_entries([SymbolVertex.t()], Graph.t()) :: [Clarity.Introspector.entry()]
  defp provenance_entries(symbol_vertices, graph) do
    Enum.flat_map(symbol_vertices, &provenance_step_entries(&1, graph))
  end

  @spec provenance_step_entries(SymbolVertex.t(), Graph.t()) :: [Clarity.Introspector.entry()]
  defp provenance_step_entries(symbol_vertex, graph) do
    Enum.flat_map(symbol_vertex.provenance, fn step ->
      case provenance_edge(symbol_vertex, step, graph) do
        {:ok, entry} -> [entry]
        :error -> []
      end
    end)
  end

  @spec provenance_edge(SymbolVertex.t(), map(), Graph.t()) ::
          {:ok, Clarity.Introspector.entry()} | :error
  defp provenance_edge(symbol_vertex, step, graph) do
    with {:ok, label} <- provenance_label(Map.get(step, "stage")),
         {:ok, by_vertex} <- injector_vertex(Map.get(step, "by"), graph) do
      {:ok, {:edge, symbol_vertex, by_vertex, label}}
    end
  end

  @spec provenance_label(term()) :: {:ok, atom()} | :error
  defp provenance_label(stage) when is_binary(stage), do: Map.fetch(@provenance_labels, stage)
  defp provenance_label(_stage), do: :error

  @spec injector_vertex(term(), Graph.t()) :: {:ok, Vertex.t()} | :error
  defp injector_vertex(by, graph) when is_binary(by) do
    case module_atom(by) do
      nil -> :error
      module -> module_vertex(graph, module)
    end
  end

  defp injector_vertex(_by, _graph), do: :error

  @spec resolve_target(String.t(), %{String.t() => SymbolVertex.t()}, Graph.t()) ::
          {:ok, Vertex.t()} | :error
  defp resolve_target(to, vertices_by_id, _graph) when is_map_key(vertices_by_id, to) do
    Map.fetch(vertices_by_id, to)
  end

  # A `to` that is not a symbol id in this document is a module reference
  # (e.g. a relationship's destination, or a named type). Resolve it against
  # the graph's existing vertices: the Ash resource vertex when one exists,
  # otherwise the plain module vertex.
  defp resolve_target(module_ref, _vertices_by_id, graph) when is_binary(module_ref) do
    case module_atom(module_ref) do
      nil -> :error
      module -> module_vertex(graph, module)
    end
  end

  @spec module_vertex(Graph.t(), module()) :: {:ok, Vertex.t()} | :error
  defp module_vertex(graph, module) do
    vertex =
      Graph.get_vertex(graph, Util.id(Vertex.Ash.Resource, [module])) ||
        graph
        |> Graph.vertices({:and, {:==, :vertex_type, Module}, {:==, {:field, :module}, module}})
        |> List.first()

    case vertex do
      nil -> :error
      vertex -> {:ok, vertex}
    end
  end

  # Manifest identifiers must never be converted to atoms with
  # String.to_atom/1 (RFC §8); only atoms that already exist — i.e. modules
  # Clarity has live-introspected — can be targets of cross-link edges.
  @spec module_atom(String.t()) :: module() | nil
  defp module_atom(name) do
    String.to_existing_atom("Elixir." <> name)
  rescue
    ArgumentError -> nil
  end
end
