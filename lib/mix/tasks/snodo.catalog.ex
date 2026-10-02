defmodule Mix.Tasks.Snodo.Catalog do
  use Mix.Task

  alias Snodo.Catalog.Markdown
  alias Snodo.Client
  alias Snodo.Error
  alias Snodo.Server.Runtime

  @shortdoc "Renders an MCP server catalog as Markdown"

  @moduledoc """
  Renders the catalog a client can discover as Markdown.

      mix snodo.catalog --server MyApp.Server --output catalog.md
      mix snodo.catalog --url http://127.0.0.1:4000/mcp

  Exactly one of `--server` and `--url` is required. A local server must expose
  `runtime/0`; `--url` connects through `Snodo.Client` to a running Streamable
  HTTP server. Both paths use the client's discovery and paginated list calls,
  so the document reflects the selected protocol's visible catalog. Output
  goes to stdout unless `--output PATH` is given.
  """

  @impl Mix.Task
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [server: :string, url: :string, output: :string],
        aliases: [o: :output]
      )

    if positional != [] or invalid != [] or not one_source?(options) do
      Mix.raise("usage: mix snodo.catalog (--server MODULE | --url URL) [--output PATH]")
    end

    Mix.Task.run("app.start")
    client = open_client!(options)

    try do
      case Markdown.collect(client) do
        {:ok, catalog} -> catalog |> Markdown.render() |> emit(Keyword.get(options, :output))
        {:error, %Error{} = error} -> Mix.raise("catalog request failed: #{error.message}")
      end
    after
      Client.close(client)
    end
  end

  defp one_source?(options) do
    sources = Enum.count([:server, :url], &Keyword.has_key?(options, &1))
    sources == 1
  end

  defp open_client!(options) do
    result =
      case Keyword.fetch(options, :server) do
        {:ok, server} -> Client.direct(runtime!(server))
        :error -> Client.connect({:http, Keyword.fetch!(options, :url)})
      end

    case result do
      {:ok, client} -> client
      {:error, %Error{} = error} -> Mix.raise("catalog connection failed: #{error.message}")
    end
  end

  defp runtime!(name) do
    module = name |> String.split(".") |> Module.concat()

    unless Code.ensure_loaded?(module) and function_exported?(module, :runtime, 0) do
      Mix.raise("#{name} must be a loaded Snodo server module with runtime/0")
    end

    case module.runtime() do
      %Runtime{} = runtime -> runtime
      _other -> Mix.raise("#{name}.runtime/0 must return Snodo.Server.Runtime")
    end
  end

  defp emit(markdown, nil), do: IO.write(markdown)

  defp emit(markdown, path) when is_binary(path) and path != "" do
    File.write!(path, markdown)
    Mix.shell().info("Wrote catalog to #{path}")
  end

  defp emit(_markdown, _path), do: Mix.raise("--output must be a non-empty path")
end
