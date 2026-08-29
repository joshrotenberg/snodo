defmodule MCP.Router do
  @moduledoc """
  An immutable registry and synchronous protocol-neutral dispatcher.

  The router owns no process, connection, session, or application state.
  """

  alias MCP.Completion
  alias MCP.Context
  alias MCP.Error
  alias MCP.Prompt
  alias MCP.Prompt.Definition, as: PromptDefinition
  alias MCP.Resource
  alias MCP.Resource.Definition, as: ResourceDefinition
  alias MCP.Result
  alias MCP.Schema.Validator.Passthrough
  alias MCP.Tool
  alias MCP.Tool.Definition

  @type operation ::
          :tools_list
          | {:tools_call, String.t()}
          | :resources_list
          | :resource_templates_list
          | {:resource_read, String.t()}
          | :prompts_list
          | {:prompt_get, String.t()}
          | :completion_complete
          | term()

  @type t :: %__MODULE__{
          tools: %{optional(String.t()) => module()},
          prompts: %{optional(String.t()) => module()},
          resources: %{optional(String.t()) => module()},
          resource_templates: %{optional(String.t()) => module()},
          resource_names: %{optional(String.t()) => module()}
        }

  defstruct tools: %{}, prompts: %{}, resources: %{}, resource_templates: %{}, resource_names: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec register_tool(t(), module()) :: t()
  def register_tool(%__MODULE__{} = router, tool) when is_atom(tool) do
    Tool.validate_module!(tool)
    name = tool.name()

    unless is_binary(name) and name != "" do
      raise ArgumentError, "tool #{inspect(tool)} returned an invalid name"
    end

    case router.tools do
      %{^name => existing} when existing != tool ->
        raise ArgumentError,
              "tool name #{inspect(name)} is already registered by #{inspect(existing)}"

      _ ->
        %{router | tools: Map.put(router.tools, name, tool)}
    end
  end

  @spec list_tools(t()) :: [Definition.t()]
  def list_tools(%__MODULE__{} = router) do
    router.tools
    |> Enum.sort_by(fn {name, _module} -> name end)
    |> Enum.map(fn {_name, module} -> Tool.definition(module) end)
  end

  @spec register_prompt(t(), module()) :: t()
  def register_prompt(%__MODULE__{} = router, prompt) when is_atom(prompt) do
    Prompt.validate_module!(prompt)
    name = prompt.definition().name

    case router.prompts do
      %{^name => existing} when existing != prompt ->
        raise ArgumentError,
              "prompt name #{inspect(name)} is already registered by #{inspect(existing)}"

      _available ->
        %{router | prompts: Map.put(router.prompts, name, prompt)}
    end
  end

  @spec list_prompts(t()) :: [PromptDefinition.t()]
  def list_prompts(%__MODULE__{} = router) do
    router.prompts
    |> Enum.sort_by(fn {name, _module} -> name end)
    |> Enum.map(fn {_name, module} -> Prompt.definition(module) end)
  end

  @spec register_resource(t(), module()) :: t()
  def register_resource(%__MODULE__{} = router, resource) when is_atom(resource) do
    Resource.validate_module!(resource)
    definition = resource.definition()
    reject_resource_name_collision!(router, definition, resource)

    case definition do
      %ResourceDefinition{kind: :resource, uri: uri} ->
        register_direct_resource(router, resource, uri)

      %ResourceDefinition{kind: :template, uri_template: template} ->
        register_resource_template(router, resource, template)
    end
  end

  @spec list_resources(t()) :: [ResourceDefinition.t()]
  def list_resources(%__MODULE__{} = router) do
    router.resources
    |> Enum.sort_by(fn {uri, _module} -> uri end)
    |> Enum.map(fn {_uri, module} -> Resource.definition(module) end)
  end

  @spec list_resource_templates(t()) :: [ResourceDefinition.t()]
  def list_resource_templates(%__MODULE__{} = router) do
    router.resource_templates
    |> Enum.sort_by(fn {template, _module} -> template end)
    |> Enum.map(fn {_template, module} -> Resource.definition(module) end)
  end

  @doc "Returns whether any registered prompt or resource template supports completion."
  @spec completion_capable?(t()) :: boolean()
  def completion_capable?(%__MODULE__{} = router) do
    Enum.any?(router.prompts, fn {_name, prompt} ->
      prompt.definition().completion_arguments != []
    end) or
      Enum.any?(router.resource_templates, fn {_template, resource} ->
        resource.definition().completion_arguments != []
      end)
  end

  @spec dispatch(t(), operation(), map(), Context.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def dispatch(router, operation, params, context, opts \\ [])

  def dispatch(%__MODULE__{} = router, :tools_list, _params, %Context{}, _opts) do
    {:ok, Result.tools(list_tools(router))}
  end

  def dispatch(%__MODULE__{} = router, :prompts_list, _params, %Context{}, _opts) do
    {:ok, Result.prompts(list_prompts(router))}
  end

  def dispatch(%__MODULE__{} = router, :resources_list, _params, %Context{}, _opts) do
    {:ok, Result.resources(list_resources(router))}
  end

  def dispatch(%__MODULE__{} = router, :resource_templates_list, _params, %Context{}, _opts) do
    {:ok, Result.resource_templates(list_resource_templates(router))}
  end

  def dispatch(
        %__MODULE__{} = router,
        :completion_complete,
        params,
        %Context{} = context,
        _opts
      )
      when is_map(params) do
    with {:ok, completion} <- Completion.parse(params),
         {:ok, target} <- fetch_completion_target(router, completion),
         :ok <- validate_completion_argument(target, completion),
         :ok <- validate_completion_context(target, completion) do
      invoke_completion(target, completion, context)
    end
  end

  def dispatch(
        %__MODULE__{} = router,
        {:prompt_get, name},
        params,
        %Context{} = context,
        _opts
      )
      when is_binary(name) and is_map(params) do
    with {:ok, prompt} <- fetch_prompt(router, name),
         {:ok, arguments} <- fetch_prompt_arguments(params),
         :ok <- validate_required_prompt_arguments(prompt.definition(), arguments) do
      invoke_prompt(prompt, arguments, context)
    end
  end

  def dispatch(
        %__MODULE__{} = router,
        {:resource_read, uri},
        params,
        %Context{} = context,
        _opts
      )
      when is_binary(uri) and is_map(params) do
    with {:ok, resource} <- resolve_resource(router, uri) do
      invoke_resource(resource, params, context)
    end
  end

  def dispatch(
        %__MODULE__{} = router,
        {:tools_call, name},
        params,
        %Context{} = context,
        opts
      )
      when is_binary(name) and is_map(params) and is_list(opts) do
    validator = Keyword.get(opts, :schema_validator, Passthrough)

    with {:ok, tool} <- fetch_tool(router, name),
         {:ok, arguments} <- fetch_arguments(params),
         :ok <- validate_input(validator, arguments, tool.input_schema()),
         {:ok, result} <- invoke(tool, arguments, context),
         :ok <- validate_output(validator, result, tool.output_schema()) do
      {:ok, result}
    end
  end

  def dispatch(%__MODULE__{}, _operation, _params, %Context{}, _opts) do
    {:error, Error.method_not_found("unregistered operation")}
  end

  defp fetch_tool(%__MODULE__{tools: tools}, name) do
    case Map.fetch(tools, name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, Error.invalid_params("Unknown tool: #{name}")}
    end
  end

  defp fetch_prompt(%__MODULE__{prompts: prompts}, name) do
    case Map.fetch(prompts, name) do
      {:ok, prompt} -> {:ok, prompt}
      :error -> {:error, Error.invalid_params("Unknown prompt: #{name}")}
    end
  end

  defp fetch_completion_target(
         %__MODULE__{prompts: prompts},
         %Completion{reference_type: :prompt, reference: name}
       ) do
    case Map.fetch(prompts, name) do
      {:ok, prompt} -> {:ok, {:prompt, prompt}}
      :error -> {:error, Error.invalid_params("Unknown completion prompt: #{name}")}
    end
  end

  defp fetch_completion_target(
         %__MODULE__{resource_templates: templates},
         %Completion{reference_type: :resource_template, reference: uri_template}
       ) do
    case Map.fetch(templates, uri_template) do
      {:ok, resource} ->
        {:ok, {:resource_template, resource}}

      :error ->
        {:error,
         Error.invalid_params("Unknown completion resource template", %{
           "uri" => uri_template
         })}
    end
  end

  defp validate_completion_argument({kind, module}, %Completion{argument: argument}) do
    if argument in module.definition().completion_arguments do
      :ok
    else
      {:error,
       Error.invalid_params("Argument does not support completion", %{
         "argument" => argument,
         "referenceType" => completion_reference_type(kind)
       })}
    end
  end

  defp validate_completion_context(
         {:prompt, prompt},
         %Completion{arguments: arguments}
       ) do
    declared = prompt.definition().arguments |> Enum.map(&Map.fetch!(&1, "name")) |> MapSet.new()
    unknown = arguments |> Map.keys() |> Enum.reject(&MapSet.member?(declared, &1)) |> Enum.sort()

    case unknown do
      [] ->
        :ok

      names ->
        {:error,
         Error.invalid_params("Unknown prompt completion context arguments", %{"unknown" => names})}
    end
  end

  defp validate_completion_context({:resource_template, _resource}, %Completion{}), do: :ok

  defp completion_reference_type(:prompt), do: "ref/prompt"
  defp completion_reference_type(:resource_template), do: "ref/resource"

  defp register_direct_resource(router, resource, uri) do
    reject_registry_collision!(router.resources, uri, resource, "resource URI")
    reject_matching_templates!(router.resource_templates, uri, resource)

    %{
      router
      | resources: Map.put(router.resources, uri, resource),
        resource_names: Map.put(router.resource_names, resource.definition().name, resource)
    }
  end

  defp register_resource_template(router, resource, template) do
    reject_registry_collision!(
      router.resource_templates,
      template,
      resource,
      "resource URI template"
    )

    reject_matching_resources!(router.resources, resource)

    %{
      router
      | resource_templates: Map.put(router.resource_templates, template, resource),
        resource_names: Map.put(router.resource_names, resource.definition().name, resource)
    }
  end

  defp reject_resource_name_collision!(router, definition, resource) do
    name = definition.name

    case router.resource_names do
      %{^name => existing} when existing != resource ->
        raise ArgumentError,
              "resource name #{inspect(name)} is already registered by #{inspect(existing)}"

      _available ->
        :ok
    end
  end

  defp reject_registry_collision!(registry, key, resource, label) do
    case registry do
      %{^key => existing} when existing != resource ->
        raise ArgumentError,
              "#{label} #{inspect(key)} is already registered by #{inspect(existing)}"

      _available ->
        :ok
    end
  end

  defp reject_matching_templates!(templates, uri, resource) do
    case matching_modules(templates, uri) do
      {:ok, []} ->
        :ok

      {:ok, [existing | _rest]} when existing == resource ->
        :ok

      {:ok, [existing | _rest]} ->
        raise ArgumentError,
              "resource URI #{inspect(uri)} is already matched by #{inspect(existing)}"

      {:error, reason} ->
        raise ArgumentError,
              "resource template matcher failed while registering #{inspect(resource)}: #{inspect(reason)}"
    end
  end

  defp reject_matching_resources!(resources, resource) do
    Enum.each(resources, fn {uri, existing} ->
      case safe_matches(resource, uri) do
        {:ok, false} ->
          :ok

        {:ok, true} when existing == resource ->
          :ok

        {:ok, true} ->
          raise ArgumentError,
                "resource template #{inspect(resource)} also matches URI owned by #{inspect(existing)}"

        {:error, reason} ->
          raise ArgumentError,
                "resource template matcher failed for #{inspect(resource)}: #{inspect(reason)}"
      end
    end)
  end

  defp resolve_resource(%__MODULE__{} = router, uri) do
    direct =
      case Map.fetch(router.resources, uri) do
        {:ok, module} -> [module]
        :error -> []
      end

    case matching_modules(router.resource_templates, uri) do
      {:ok, templates} ->
        case Enum.uniq(direct ++ templates) do
          [resource] -> {:ok, resource}
          [] -> {:error, Error.invalid_params("Resource not found", %{"uri" => uri})}
          _many -> {:error, Error.internal("Multiple resource routes matched the requested URI")}
        end

      {:error, reason} ->
        {:error, Error.internal("Resource matcher failed", reason)}
    end
  end

  defp matching_modules(templates, uri) do
    Enum.reduce_while(templates, {:ok, []}, fn {_template, resource}, {:ok, matches} ->
      case safe_matches(resource, uri) do
        {:ok, true} -> {:cont, {:ok, [resource | matches]}}
        {:ok, false} -> {:cont, {:ok, matches}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp safe_matches(resource, uri) do
    case resource.matches?(uri) do
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, {:invalid_matcher_return, resource, other}}
    end
  rescue
    exception -> {:error, {:matcher_raised, resource, exception, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:matcher_terminated, resource, kind, reason, __STACKTRACE__}}
  end

  defp invoke_resource(resource, params, context) do
    case resource.read(params, context) do
      {:ok, %Result{kind: :resource_read, value: contents} = result} when is_list(contents) ->
        Enum.each(contents, &Resource.validate_content!/1)
        {:ok, result}

      {:ok, %Result{}} ->
        {:error, Error.internal("Resource returned the wrong result kind")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.internal("Resource read failed", reason)}

      other ->
        {:error, Error.internal("Resource returned an invalid result", other)}
    end
  rescue
    exception ->
      {:error, Error.internal("Resource raised an exception", {exception, __STACKTRACE__})}
  catch
    kind, reason ->
      {:error, Error.internal("Resource terminated unexpectedly", {kind, reason, __STACKTRACE__})}
  end

  defp fetch_arguments(params) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) -> {:ok, arguments}
      _arguments -> {:error, Error.invalid_params("Tool arguments must be an object")}
    end
  end

  defp fetch_prompt_arguments(params) do
    case Map.get(params, "arguments", %{}) do
      arguments when is_map(arguments) ->
        validate_prompt_argument_map(arguments)

      _arguments ->
        {:error, Error.invalid_params("Prompt arguments must be an object")}
    end
  end

  defp validate_prompt_argument_map(arguments) do
    if Enum.all?(arguments, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      {:ok, arguments}
    else
      {:error, Error.invalid_params("Prompt arguments must map strings to strings")}
    end
  end

  defp validate_required_prompt_arguments(%PromptDefinition{} = definition, arguments) do
    missing =
      definition.arguments
      |> Enum.filter(&Map.get(&1, "required", false))
      |> Enum.map(&Map.fetch!(&1, "name"))
      |> Enum.reject(&Map.has_key?(arguments, &1))

    case missing do
      [] ->
        :ok

      names ->
        {:error, Error.invalid_params("Missing required prompt arguments", %{"missing" => names})}
    end
  end

  defp invoke_prompt(prompt, arguments, context) do
    case prompt.render(arguments, context) do
      {:ok,
       %Result{
         kind: :prompt_get,
         value: %{messages: messages, description: description}
       } = result}
      when is_list(messages) and (is_nil(description) or is_binary(description)) ->
        Enum.each(messages, &Prompt.validate_message!/1)
        {:ok, result}

      {:ok, %Result{}} ->
        {:error, Error.internal("Prompt returned the wrong result kind")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.internal("Prompt rendering failed", reason)}

      other ->
        {:error, Error.internal("Prompt returned an invalid result", other)}
    end
  rescue
    exception ->
      {:error, Error.internal("Prompt raised an exception", {exception, __STACKTRACE__})}
  catch
    kind, reason ->
      {:error, Error.internal("Prompt terminated unexpectedly", {kind, reason, __STACKTRACE__})}
  end

  defp invoke_completion({_kind, module}, completion, context) do
    case module.complete(completion, context) do
      {:ok, %Result{kind: :completion} = result} ->
        case Completion.validate_result(result) do
          :ok ->
            {:ok, result}

          {:error, reason} ->
            {:error, Error.internal("Completion returned an invalid result", reason)}
        end

      {:ok, %Result{}} ->
        {:error, Error.internal("Completion returned the wrong result kind")}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.internal("Completion failed", reason)}

      other ->
        {:error, Error.internal("Completion returned an invalid result", other)}
    end
  rescue
    exception ->
      {:error, Error.internal("Completion raised an exception", {exception, __STACKTRACE__})}
  catch
    kind, reason ->
      {:error,
       Error.internal("Completion terminated unexpectedly", {kind, reason, __STACKTRACE__})}
  end

  defp invoke(tool, arguments, context) do
    case tool.call(arguments, context) do
      {:ok, result} ->
        {:ok, Result.normalize(result)}

      {:error, %Error{} = error} ->
        {:ok, Result.error(error.message, error: error)}

      {:error, reason} ->
        {:ok, Result.error(format_reason(reason), error: Error.execution(reason))}

      other ->
        {:error, Error.internal("Tool returned an invalid result", other)}
    end
  rescue
    exception ->
      {:error, Error.internal("Tool raised an exception", {exception, __STACKTRACE__})}
  catch
    kind, reason ->
      {:error, Error.internal("Tool terminated unexpectedly", {kind, reason, __STACKTRACE__})}
  end

  defp validate_input(validator, arguments, schema) do
    case run_validator(validator, arguments, schema) do
      :ok ->
        :ok

      {:invalid, _reason} ->
        {:error, Error.invalid_params("Tool arguments failed schema validation")}

      {:validator_error, reason} ->
        {:error, Error.internal("Schema validator failed", reason)}
    end
  end

  defp validate_output(_validator, %Result{kind: :error}, _schema), do: :ok
  defp validate_output(_validator, %Result{}, nil), do: :ok

  defp validate_output(validator, %Result{kind: :structured, value: value}, schema) do
    validate_output_instance(validator, value, schema)
  end

  defp validate_output(validator, %Result{kind: :raw, value: value}, schema)
       when is_map(value) do
    case Map.fetch(value, "structuredContent") do
      {:ok, structured} ->
        validate_output_instance(validator, structured, schema)

      :error ->
        {:error, Error.internal("Tool omitted structured output required by output schema")}
    end
  end

  defp validate_output(_validator, %Result{}, _schema) do
    {:error, Error.internal("Tool omitted structured output required by output schema")}
  end

  defp validate_output_instance(validator, value, schema) do
    case run_validator(validator, value, schema) do
      :ok ->
        :ok

      {:invalid, reason} ->
        {:error, Error.internal("Tool output failed schema validation", reason)}

      {:validator_error, reason} ->
        {:error, Error.internal("Schema validator failed", reason)}
    end
  end

  defp run_validator(validator, value, schema) do
    case validator.validate(value, schema) do
      :ok -> :ok
      {:error, reason} -> {:invalid, reason}
      other -> {:validator_error, {:invalid_return, other}}
    end
  rescue
    exception -> {:validator_error, {exception, __STACKTRACE__}}
  catch
    kind, reason -> {:validator_error, {kind, reason, __STACKTRACE__}}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(_reason), do: "Tool execution failed"
end
