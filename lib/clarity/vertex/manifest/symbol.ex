defmodule Clarity.Vertex.Manifest.Symbol do
  @moduledoc """
  Vertex for a symbol imported from a Spark/Ash semantic manifest
  (`semantic-manifest-v0`).

  Manifest symbols are complementary to the vertices Clarity derives from live
  introspection: they exist only when a semantic manifest is configured, and
  they carry what live introspection cannot — the manifest's source spans and
  provenance chains. Live vertices (such as `Clarity.Vertex.Ash.Attribute`)
  describe what a module *is*; a manifest symbol vertex additionally knows
  *where it was declared* and *what produced it*.

  The vertex id is derived from the manifest's structural symbol id
  (`ash:v0:<module>#<dsl_path>/<name>[:<discriminator>]`). Because that grammar
  uses characters (`:`, `#`, `/`, `!`, `?`) that would collide under
  `Clarity.Vertex.Util.id/2`'s lossy normalization (e.g. `create!/2` and
  `create/2` both normalize to `create-2`), the id is percent-encoded instead.
  """

  alias Clarity.SourceLocation

  @enforce_keys [:manifest_module, :symbol_id, :kind]
  defstruct [:manifest_module, :symbol_id, :kind, :name, :span, :provenance, :symbol]

  @typedoc """
  A symbol imported from a semantic manifest document.

  - `manifest_module` - the manifest document's `module` (dotted string)
  - `symbol_id` - the manifest's structural symbol id
  - `kind` - the manifest symbol kind (e.g. `attribute`, `action`, `policy`)
  - `name` - the symbol name, or `nil` for unnamed symbols (policies)
  - `span` - the manifest span map, or `nil` when compiled without `debug_info`
  - `provenance` - the ordered provenance chain (oldest step first)
  - `symbol` - the full raw symbol map from the document
  """
  @type t() :: %__MODULE__{
          manifest_module: String.t(),
          symbol_id: String.t(),
          kind: String.t(),
          name: String.t() | nil,
          span: map() | nil,
          provenance: [map()],
          symbol: map() | nil
        }

  @doc """
  Percent-encodes a manifest symbol id into a vertex-id-safe string.

  Every byte outside `[A-Za-z0-9_.~-]` is rendered as `%XX`, so distinct
  symbol ids always produce distinct vertex ids.

  ## Examples

      iex> Clarity.Vertex.Manifest.Symbol.encode_id("ash:v0:Demo.Accounts.User#attributes/name")
      "ash%3Av0%3ADemo.Accounts.User%23attributes%2Fname"

      iex> Clarity.Vertex.Manifest.Symbol.encode_id("ash:v0:M#code_interface/create!/2")
      "ash%3Av0%3AM%23code_interface%2Fcreate%21%2F2"

  """
  @spec encode_id(String.t()) :: String.t()
  def encode_id(symbol_id) do
    for <<byte <- symbol_id>>, into: "", do: encode_byte(byte)
  end

  @spec encode_byte(byte()) :: String.t()
  defp encode_byte(byte)
       when byte in ?a..?z
       when byte in ?A..?Z
       when byte in ?0..?9
       when byte in [?_, ?., ?-, ?~],
       do: <<byte>>

  defp encode_byte(byte) do
    byte
    |> Integer.to_string(16)
    |> String.pad_leading(2, "0")
    |> String.upcase()
    |> then(&"%#{&1}")
  end

  defimpl Clarity.Vertex do
    @impl Clarity.Vertex
    def id(%@for{symbol_id: symbol_id}) do
      "manifest-symbol:" <> @for.encode_id(symbol_id)
    end

    @impl Clarity.Vertex
    def type_label(_vertex), do: "Manifest Symbol"

    @impl Clarity.Vertex
    def name(%@for{name: name, kind: kind, symbol_id: symbol_id}) do
      name || fallback_name(kind, symbol_id)
    end

    # Unnamed symbols (policies use ordinal discriminators) fall back to
    # "<kind> <id tail>", e.g. "policy 0" for `…#policies/0`.
    @spec fallback_name(String.t(), String.t()) :: String.t()
    defp fallback_name(kind, symbol_id) do
      tail =
        symbol_id
        |> String.split("#", parts: 2)
        |> List.last()
        |> String.split("/")
        |> List.last()

      case tail do
        "" -> kind
        tail -> kind <> " " <> tail
      end
    end
  end

  defimpl Clarity.Vertex.GraphGroupProvider do
    @impl Clarity.Vertex.GraphGroupProvider
    def graph_group(%@for{manifest_module: manifest_module}), do: [manifest_module]
  end

  defimpl Clarity.Vertex.GraphShapeProvider do
    @impl Clarity.Vertex.GraphShapeProvider
    def shape(_vertex), do: "note"
  end

  defimpl Clarity.Vertex.SourceLocationProvider do
    @impl Clarity.Vertex.SourceLocationProvider
    def source_location(%@for{span: nil}), do: nil

    def source_location(%@for{span: span}), do: build(span)

    # `span: null` is the normal case for manifests emitted without
    # `debug_info` (fidelity "absent") and is not an error.
    @spec build(term()) :: SourceLocation.t() | nil
    defp build(%{"file" => file, "start" => %{"line" => line} = start})
         when is_binary(file) and is_integer(line) and line > 0 do
      anno =
        line
        |> :erl_anno.new()
        |> add_column(start["column"])
        |> then(&:erl_anno.set_file(String.to_charlist(file), &1))

      %SourceLocation{application: nil, module: nil, anno: anno}
    end

    defp build(_span), do: nil

    @spec add_column(:erl_anno.anno(), term()) :: :erl_anno.anno()
    defp add_column(anno, column) when is_integer(column) and column > 0 do
      :erl_anno.set_location({:erl_anno.line(anno), column}, anno)
    end

    defp add_column(anno, _column), do: anno
  end

  defimpl Clarity.Vertex.TooltipProvider do
    @impl Clarity.Vertex.TooltipProvider
    def tooltip(%@for{} = vertex) do
      [
        "**Kind:** `",
        vertex.kind,
        "`\n\n",
        "**Symbol id:** `",
        vertex.symbol_id,
        "`\n\n",
        span_section(vertex.span),
        provenance_section(vertex.provenance)
      ]
    end

    @spec span_section(map() | nil) :: iodata()
    defp span_section(nil), do: []

    defp span_section(%{"file" => file, "start" => %{"line" => line}}) when is_integer(line) do
      ["**Declared at:** `", to_string(file), ":", Integer.to_string(line), "`\n\n"]
    end

    defp span_section(_span), do: []

    @spec provenance_section([map()]) :: iodata()
    defp provenance_section(provenance) do
      steps =
        provenance
        |> Enum.map(&provenance_step/1)
        |> Enum.reject(&is_nil/1)

      case steps do
        [] -> []
        steps -> ["**Provenance:**\n\n" | Enum.map(steps, &["- ", &1, "\n"])]
      end
    end

    @spec provenance_step(map()) :: iodata() | nil
    defp provenance_step(%{"stage" => stage} = step) do
      [
        "`",
        to_string(stage),
        "`",
        by_fragment(Map.get(step, "by")),
        note_fragment(Map.get(step, "note"))
      ]
    end

    defp provenance_step(_step), do: nil

    @spec by_fragment(term()) :: iodata()
    defp by_fragment(by) when is_binary(by), do: [" by `", by, "`"]
    defp by_fragment(_by), do: []

    @spec note_fragment(term()) :: iodata()
    defp note_fragment(note) when is_binary(note) do
      [" — ", note |> String.replace("\n", " ") |> String.slice(0, 160)]
    end

    defp note_fragment(_note), do: []
  end
end
