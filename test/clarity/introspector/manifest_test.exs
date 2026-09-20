defmodule Clarity.Introspector.ManifestTest do
  # The introspector reads its configuration from the application environment,
  # so these tests must not run concurrently with any other test.
  use ExUnit.Case, async: false

  alias Clarity.Graph
  alias Clarity.Introspector.Manifest, as: ManifestIntrospector
  alias Clarity.Introspector.Manifest.Store
  alias Clarity.SourceLocation
  alias Clarity.Vertex
  alias Clarity.Vertex.Manifest.Symbol, as: SymbolVertex
  alias Clarity.Vertex.Module, as: ModuleVertex
  alias Clarity.Vertex.Root

  doctest SymbolVertex

  @fixture_path Path.expand("../../support/fixtures/semantic_manifest/team.manifest.json", __DIR__)

  # The fixture's module. The AshEnterprise app does not exist in Clarity's
  # test environment, so manifest references to its modules exercise the
  # "target not resolvable" paths.
  @team_module :"Elixir.AshEnterprise.Accounts.Team"
  @demo_module Demo.Accounts.User
  @demo_injector Demo.Accounts

  setup do
    Application.put_env(:clarity, :semantic_manifest, path: @fixture_path)

    on_exit(fn -> Application.delete_env(:clarity, :semantic_manifest) end)

    :ok
  end

  describe "source_vertex_types/0" do
    test "runs on module vertices" do
      assert ManifestIntrospector.source_vertex_types() == [ModuleVertex]
    end
  end

  describe "introspect_vertex/2 - graceful degradation" do
    test "is a no-op when no manifest is configured" do
      Application.delete_env(:clarity, :semantic_manifest)
      {graph, module_vertex} = graph_with_module(@demo_module)

      assert {:ok, []} = ManifestIntrospector.introspect_vertex(module_vertex, graph)
    end

    test "is a no-op when the configured file does not exist" do
      Application.put_env(:clarity, :semantic_manifest, path: "/nonexistent/manifest.json")
      {graph, module_vertex} = graph_with_module(@demo_module)

      assert {:ok, []} = ManifestIntrospector.introspect_vertex(module_vertex, graph)
    end

    test "is a no-op on malformed JSON" do
      path = write_manifest("not json at all {{{")

      Application.put_env(:clarity, :semantic_manifest, path: path)
      {graph, module_vertex} = graph_with_module(@demo_module)

      assert {:ok, []} = ManifestIntrospector.introspect_vertex(module_vertex, graph)
    end

    test "is a no-op on JSON that is not a manifest document" do
      path = write_manifest(~s({"module": 42, "symbols": []}))
      Application.put_env(:clarity, :semantic_manifest, path: path)

      {graph, module_vertex} = graph_with_module(@demo_module)
      assert {:ok, []} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      path = write_manifest(~s({"module": "Demo.Accounts.User"}))
      Application.put_env(:clarity, :semantic_manifest, path: path)

      assert {:ok, []} = ManifestIntrospector.introspect_vertex(module_vertex, graph)
    end

    test "is a no-op when the manifest declares a different module" do
      {graph, module_vertex} = graph_with_module(@demo_module)

      assert {:ok, []} = ManifestIntrospector.introspect_vertex(module_vertex, graph)
    end

    test "ignores non-module vertices" do
      root = %Root{}
      graph = Graph.new()
      Graph.add_vertex(graph, root, root)

      assert {:ok, []} = ManifestIntrospector.introspect_vertex(root, graph)
    end
  end

  describe "introspect_vertex/2 - symbol vertices" do
    test "emits one vertex per known manifest symbol, attached to the module vertex" do
      {graph, module_vertex} = graph_with_module(@team_module)

      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      {vertices, rest} = Enum.split_with(entries, &match?({:vertex, _}, &1))

      # 8 of the fixture's 9 symbols: the "some_future_kind" symbol is skipped
      # per semantic-manifest-v0 §6.2 (consumers skip unknown kinds).
      assert length(vertices) == 8

      assert [_] =
               Enum.filter(vertices, fn {:vertex, %SymbolVertex{} = vertex} ->
                 vertex.symbol_id == "ash:v0:AshEnterprise.Accounts.Team#attributes/name" and
                   vertex.kind == "attribute" and
                   vertex.name == "name" and
                   vertex.manifest_module == "AshEnterprise.Accounts.Team"
               end)

      # One :manifest_symbol edge per symbol vertex, from the module vertex.
      attach_edges = Enum.filter(rest, &match?({:edge, _from, _to, :manifest_symbol}, &1))
      assert length(attach_edges) == 8

      assert Enum.all?(attach_edges, fn {:edge, from, to, _label} ->
               from == module_vertex and match?(%SymbolVertex{}, to)
             end)
    end

    test "symbol ids that would collide under naive normalization stay distinct" do
      {graph, module_vertex} = graph_with_module(@team_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      ids =
        entries
        |> Enum.filter(&match?({:vertex, _}, &1))
        |> MapSet.new(fn {:vertex, vertex} -> Vertex.id(vertex) end)

      create = Vertex.id(symbol_vertex(entries, "#code_interface/create/2"))
      bang = Vertex.id(symbol_vertex(entries, "#code_interface/create!/2"))

      assert MapSet.member?(ids, create)
      assert MapSet.member?(ids, bang)
      refute create == bang
    end

    test "unnamed symbols fall back to a kind-and-ordinal display name" do
      {graph, module_vertex} = graph_with_module(@team_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      policy = symbol_vertex(entries, "#policies/0")

      assert Vertex.name(policy) == "policy 0"
      assert Vertex.type_label(policy) == "Manifest Symbol"
    end
  end

  describe "introspect_vertex/2 - relation edges" do
    test "emits edges between symbol vertices for resolvable relations" do
      {graph, module_vertex} = graph_with_module(@team_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      assert edge(
               entries,
               from_id: "#resource",
               to_id: "#attributes/name",
               label: :contains
             )

      assert edge(
               entries,
               from_id: "#resource",
               to_id: "#policies/0",
               label: :guarded_by
             )

      # The provenance edges this task is about: the generated code-interface
      # functions point back at the DSL declarations they implement, and the
      # bang variant is generated from the plain one.
      assert edge(
               entries,
               from_id: "#code_interface/create/2",
               to_id: "#actions/create",
               label: :implements_action
             )

      assert edge(
               entries,
               from_id: "#code_interface/create/2",
               to_id: "#code_interface/create!/2",
               label: :generated_from
             )
    end

    test "skips relations whose endpoints are not resolvable" do
      {graph, module_vertex} = graph_with_module(@team_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      # `to` is a module ref with no vertex in the graph.
      refute edge(entries,
               from_id: "#attributes/lifecycle_status",
               label: :transformed_from
             )

      # `from` is a symbol that the (abridged) document does not carry.
      refute edge(entries, label: :references_resource)
    end

    test "resolves module-ref relation targets to graph vertices when present" do
      manifest = """
      {
        "module": "Demo.Accounts.User",
        "symbols": [
          {"id": "ash:v0:Demo.Accounts.User#relationships/parent", "kind": "relationship",
           "name": "parent", "dsl_path": ["relationships"], "span": null}
        ],
        "relations": [
          {"from": "ash:v0:Demo.Accounts.User#relationships/parent",
           "to": "Demo.Accounts.User", "kind": "references_resource"}
        ]
      }
      """

      path = write_manifest(manifest)
      Application.put_env(:clarity, :semantic_manifest, path: path)

      {graph, module_vertex} = graph_with_module(@demo_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      assert {:edge, %SymbolVertex{symbol_id: "ash:v0:Demo.Accounts.User#relationships/parent"},
              %ModuleVertex{module: @demo_module}, :references_resource} =
               edge_tuple(entries, label: :references_resource)
    end

    test "degrades unknown relation kinds to string edge labels" do
      manifest = """
      {
        "module": "Demo.Accounts.User",
        "symbols": [
          {"id": "ash:v0:Demo.Accounts.User#a", "kind": "attribute", "name": "a",
           "dsl_path": ["attributes"], "span": null},
          {"id": "ash:v0:Demo.Accounts.User#b", "kind": "attribute", "name": "b",
           "dsl_path": ["attributes"], "span": null}
        ],
        "relations": [
          {"from": "ash:v0:Demo.Accounts.User#a", "to": "ash:v0:Demo.Accounts.User#b",
           "kind": "frobnicates"}
        ]
      }
      """

      path = write_manifest(manifest)
      Application.put_env(:clarity, :semantic_manifest, path: path)

      {graph, module_vertex} = graph_with_module(@demo_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      # Never an atom created from manifest data (RFC §8).
      assert {:edge, %SymbolVertex{symbol_id: "ash:v0:Demo.Accounts.User#a"},
              %SymbolVertex{symbol_id: "ash:v0:Demo.Accounts.User#b"}, "frobnicates"} =
               edge_tuple(entries, label: "frobnicates")
    end
  end

  describe "introspect_vertex/2 - provenance edges" do
    test "links macro-injected symbols to the injecting module's vertex" do
      manifest = """
      {
        "module": "Demo.Accounts.User",
        "symbols": [
          {"id": "ash:v0:Demo.Accounts.User#attributes/organization_id", "kind": "attribute",
           "name": "organization_id", "dsl_path": ["attributes"], "span": null,
           "provenance": [
             {"stage": "declared", "by": null},
             {"stage": "macro_injected", "by": "Demo.Accounts",
              "span": {"file": "lib/demo/accounts/user.ex",
                       "start": {"line": 3, "column": 3}, "end": null, "fidelity": "exact"},
              "note": "use/2"}
           ]}
        ],
        "relations": []
      }
      """

      path = write_manifest(manifest)
      Application.put_env(:clarity, :semantic_manifest, path: path)

      {graph, module_vertex} = graph_with_module(@demo_module)
      injector_vertex = %ModuleVertex{module: @demo_injector}
      Graph.add_vertex(graph, injector_vertex, %Root{})

      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      assert {:edge, %SymbolVertex{symbol_id: "ash:v0:Demo.Accounts.User#attributes/organization_id"},
              %ModuleVertex{module: @demo_injector}, :macro_injected_by} =
               edge_tuple(entries, label: :macro_injected_by)
    end

    test "skips provenance steps whose injector has no vertex in the graph" do
      {graph, module_vertex} = graph_with_module(@team_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      # lifecycle_status is macro_injected by AshEnterprise.Platform.Resource
      # and transformer_added by AddSystemAttributes — neither module exists
      # in Clarity's test graph, so neither edge may be emitted.
      refute edge(entries,
               from_id: "#attributes/lifecycle_status",
               label: :macro_injected_by
             )

      refute edge(entries,
               from_id: "#attributes/lifecycle_status",
               label: :transformed_from
             )
    end
  end

  describe "source locations from spans" do
    test "builds a SourceLocation from a span with line and column" do
      {graph, module_vertex} = graph_with_module(@team_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      name = symbol_vertex(entries, "#attributes/name")
      source_location = Vertex.SourceLocationProvider.source_location(name)

      assert %SourceLocation{} = source_location
      assert SourceLocation.line(source_location) == 48
      assert SourceLocation.column(source_location) == 5
      assert SourceLocation.file_path(source_location, :cwd) == "lib/ash_enterprise/accounts/team.ex"
    end

    test "returns nil for symbols without a span" do
      {graph, module_vertex} = graph_with_module(@team_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      lifecycle_status = symbol_vertex(entries, "#attributes/lifecycle_status")

      assert Vertex.SourceLocationProvider.source_location(lifecycle_status) == nil
    end

    test "tolerates line-only spans" do
      manifest = """
      {
        "module": "Demo.Accounts.User",
        "symbols": [
          {"id": "ash:v0:Demo.Accounts.User#attributes/a", "kind": "attribute", "name": "a",
           "dsl_path": ["attributes"],
           "span": {"file": "lib/demo/accounts/user.ex",
                    "start": {"line": 9, "column": null}, "end": null, "fidelity": "line_only"}}
        ],
        "relations": []
      }
      """

      path = write_manifest(manifest)
      Application.put_env(:clarity, :semantic_manifest, path: path)

      {graph, module_vertex} = graph_with_module(@demo_module)
      assert {:ok, entries} = ManifestIntrospector.introspect_vertex(module_vertex, graph)

      vertex = symbol_vertex(entries, "#attributes/a")
      source_location = Vertex.SourceLocationProvider.source_location(vertex)

      assert SourceLocation.line(source_location) == 9
      assert SourceLocation.column(source_location) == nil
    end
  end

  describe "vertex id encoding" do
    test "distinct symbol ids always produce distinct vertex ids" do
      vertex_a = %SymbolVertex{manifest_module: "M", symbol_id: "ash:v0:M#a.b", kind: "attribute"}
      vertex_b = %SymbolVertex{manifest_module: "M", symbol_id: "ash:v0:M#a-b", kind: "attribute"}

      refute Vertex.id(vertex_a) == Vertex.id(vertex_b)
      assert Vertex.id(vertex_a) == "manifest-symbol:ash%3Av0%3AM%23a.b"
    end
  end

  describe "Store.manifest_paths/0" do
    test "supports a bare string path" do
      Application.put_env(:clarity, :semantic_manifest, "/some/path.json")

      assert Store.manifest_paths() == ["/some/path.json"]
    end

    test "supports path: and paths: keyword forms" do
      Application.put_env(:clarity, :semantic_manifest, path: "/a.json")
      assert Store.manifest_paths() == ["/a.json"]

      Application.put_env(:clarity, :semantic_manifest, paths: ["/a.json", "/b.json"])
      assert Store.manifest_paths() == ["/a.json", "/b.json"]

      Application.put_env(:clarity, :semantic_manifest, path: "/a.json", paths: ["/c.json"])
      assert Store.manifest_paths() == ["/a.json", "/c.json"]
    end

    test "supports a plain list of paths" do
      Application.put_env(:clarity, :semantic_manifest, ["/a.json", "/b.json"])

      assert Store.manifest_paths() == ["/a.json", "/b.json"]
    end

    test "collects per-application registrations" do
      Application.put_env(:clarity, :semantic_manifest, path: "/global.json")
      Application.put_env(:clarity, :clarity_semantic_manifests, ["/app1.json", "/app2.json"])

      assert Store.manifest_paths() == ["/global.json", "/app1.json", "/app2.json"]
    after
      Application.delete_env(:clarity, :clarity_semantic_manifests)
    end
  end

  describe "Store.lookup/1" do
    test "finds the document declaring a module" do
      assert {:ok, %{"module" => "AshEnterprise.Accounts.Team", "symbols" => symbols}} =
               Store.lookup("AshEnterprise.Accounts.Team")

      assert is_list(symbols)
      assert :not_found = Store.lookup("Nobody.Declares.This")
    end

    test "re-reads a manifest file after it changes" do
      path = write_manifest(~s({"module": "First.Mod", "symbols": []}))
      Application.put_env(:clarity, :semantic_manifest, path: path)

      assert {:ok, %{"module" => "First.Mod"}} = Store.lookup("First.Mod")

      # Different size guarantees a fresh cache key even with coarse mtimes.
      path = write_manifest(~s({"module": "Second.Module.Renamed", "symbols": []}), path)
      Application.put_env(:clarity, :semantic_manifest, path: path)

      assert :not_found = Store.lookup("First.Mod")
      assert {:ok, %{"module" => "Second.Module.Renamed"}} = Store.lookup("Second.Module.Renamed")
    end
  end

  # Helpers

  @spec graph_with_module(module()) :: {Graph.t(), ModuleVertex.t()}
  defp graph_with_module(module) do
    graph = Graph.new()
    root = %Root{}
    Graph.add_vertex(graph, root, root)

    module_vertex = %ModuleVertex{module: module}
    Graph.add_vertex(graph, module_vertex, root)

    {graph, module_vertex}
  end

  @spec write_manifest(String.t(), Path.t() | nil) :: Path.t()
  defp write_manifest(contents, path \\ nil) do
    path = path || Path.join(System.tmp_dir!(), "clarity-manifest-#{System.unique_integer()}.json")
    File.write!(path, contents)
    path
  end

  @doc false
  @spec symbol_vertex([Clarity.Introspector.entry()], String.t()) :: SymbolVertex.t() | no_return()
  defp symbol_vertex(entries, id_suffix) do
    entries
    |> Enum.flat_map(fn
      {:vertex, %SymbolVertex{} = vertex} -> [vertex]
      _entry -> []
    end)
    |> Enum.find(fn %SymbolVertex{symbol_id: symbol_id} ->
      String.ends_with?(symbol_id, id_suffix)
    end)
    |> case do
      nil -> flunk("no manifest symbol vertex with id suffix #{inspect(id_suffix)}")
      vertex -> vertex
    end
  end

  @spec edge(
          [Clarity.Introspector.entry()],
          from_id: String.t() | nil,
          to_id: String.t() | nil,
          label: term()
        ) :: boolean()
  defp edge(entries, opts) do
    case edge_tuple(entries, opts) do
      nil -> false
      _edge -> true
    end
  end

  @spec edge_tuple(
          [Clarity.Introspector.entry()],
          from_id: String.t() | nil,
          to_id: String.t() | nil,
          label: term()
        ) ::
          {:edge, SymbolVertex.t(), Vertex.t(), term()} | nil
  defp edge_tuple(entries, opts) do
    Enum.find_value(entries, fn
      {:edge, %SymbolVertex{} = from, to, label} = entry ->
        if id_suffix_matches?(from, opts[:from_id]) and id_suffix_matches?(to, opts[:to_id]) and
             label == opts[:label] do
          entry
        end

      _entry ->
        nil
    end)
  end

  @spec id_suffix_matches?(Vertex.t(), String.t() | nil) :: boolean()
  defp id_suffix_matches?(_vertex, nil), do: true

  defp id_suffix_matches?(%SymbolVertex{symbol_id: symbol_id}, suffix), do: String.ends_with?(symbol_id, suffix)

  defp id_suffix_matches?(vertex, suffix), do: String.ends_with?(Vertex.id(vertex), suffix)
end
