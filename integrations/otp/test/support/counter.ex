defmodule SnodoTest.OTP.Counter do
  @moduledoc false
  use GenServer
  def start_link(_), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  @impl true
  def init(n), do: {:ok, n}
  @impl true
  def handle_call(:get, _from, n), do: {:reply, n, n}
  def handle_call({:add, by}, _from, n), do: {:reply, n + by, n + by}

  def handle_call({:slow, ms}, _from, n) do
    Process.sleep(ms)
    {:reply, n, n}
  end

  @impl true
  def handle_cast({:add, by}, n), do: {:noreply, n + by}
end

defmodule SnodoTest.OTP.CounterContract do
  @moduledoc false
  @behaviour Snodo.OTP.Contract
  @obj %{"type" => "object", "additionalProperties" => false}
  @by %{
    "type" => "object",
    "properties" => %{"by" => %{"type" => "integer"}},
    "required" => ["by"],
    "additionalProperties" => false
  }
  @ms %{
    "type" => "object",
    "properties" => %{"ms" => %{"type" => "integer"}},
    "required" => ["ms"],
    "additionalProperties" => false
  }
  @count %{
    "type" => "object",
    "properties" => %{"value" => %{"type" => "integer"}},
    "required" => ["value"]
  }

  @impl true
  def ops do
    [
      %{
        name: "counter_get",
        kind: :call,
        input_schema: @obj,
        output_schema: @count,
        description: "Read the counter"
      },
      %{
        name: "counter_add",
        kind: :call,
        input_schema: @by,
        output_schema: @count,
        description: "Add to the counter"
      },
      %{
        name: "counter_slow",
        kind: :call,
        input_schema: @ms,
        output_schema: @count,
        timeout: 500
      },
      %{
        name: "counter_cast_add",
        kind: :cast,
        input_schema: @by,
        description: "Add without waiting"
      }
    ]
  end

  @impl true
  def build_message("counter_get", _), do: :get
  def build_message("counter_add", %{"by" => by}), do: {:add, by}
  def build_message("counter_slow", %{"ms" => ms}), do: {:slow, ms}
  def build_message("counter_cast_add", %{"by" => by}), do: {:add, by}

  @impl true
  def encode_reply(_name, n) when is_integer(n), do: %{"value" => n}

  @impl true
  def encode_call(:get), do: {"counter_get", %{}}
  def encode_call({:add, by}), do: {"counter_add", %{"by" => by}}
  def encode_call({:slow, ms}), do: {"counter_slow", %{"ms" => ms}}
  def encode_call(_), do: :nomatch

  @impl true
  def encode_cast({:add, by}), do: {"counter_cast_add", %{"by" => by}}
  def encode_cast(_), do: :nomatch

  @impl true
  def decode_reply(_name, %{"value" => n}), do: n
end

defmodule SnodoTest.OTP.CounterServer do
  @moduledoc false
  use Snodo.Server, name: "counter-node", version: "0.1.0"
  import Snodo.OTP.Server

  alias SnodoTest.OTP.Counter
  alias SnodoTest.OTP.CounterContract

  expose(CounterContract, target: Counter)
end

defmodule SnodoTest.OTP.Recorder do
  @moduledoc false
  use GenServer

  def start_link(_arg), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(items), do: {:ok, items}

  @impl true
  def handle_call(:list, _from, items), do: {:reply, Enum.reverse(items), items}

  def handle_call({:slow, ms}, _from, items) do
    Process.sleep(ms)
    {:reply, [], items}
  end

  @impl true
  def handle_cast({:push, n}, items), do: {:noreply, [n | items]}
end

defmodule SnodoTest.OTP.RecorderContract do
  @moduledoc false
  @behaviour Snodo.OTP.Contract

  @empty %{"type" => "object", "additionalProperties" => false}
  @n %{
    "type" => "object",
    "properties" => %{"n" => %{"type" => "integer"}},
    "required" => ["n"]
  }
  @ms %{
    "type" => "object",
    "properties" => %{"ms" => %{"type" => "integer"}},
    "required" => ["ms"]
  }

  @impl true
  def ops do
    [
      %{name: "recorder_list", kind: :call, input_schema: @empty},
      %{name: "recorder_slow", kind: :call, input_schema: @ms, timeout: 100},
      %{name: "recorder_slow_long", kind: :call, input_schema: @ms, timeout: 5_000},
      %{name: "recorder_push", kind: :cast, input_schema: @n}
    ]
  end

  @impl true
  def build_message("recorder_list", _args), do: :list
  def build_message("recorder_slow", %{"ms" => ms}), do: {:slow, ms}
  def build_message("recorder_slow_long", %{"ms" => ms}), do: {:slow, ms}
  def build_message("recorder_push", %{"n" => n}), do: {:push, n}

  @impl true
  def encode_reply(_name, items), do: %{"items" => items}

  @impl true
  def encode_call(:list), do: {"recorder_list", %{}}
  def encode_call({:slow, ms}), do: {"recorder_slow", %{"ms" => ms}}
  def encode_call({:slow_long, ms}), do: {"recorder_slow_long", %{"ms" => ms}}
  def encode_call(_message), do: :nomatch

  @impl true
  def encode_cast({:push, n}), do: {"recorder_push", %{"n" => n}}
  def encode_cast(_message), do: :nomatch

  @impl true
  def decode_reply(_name, %{"items" => items}), do: items
end

defmodule SnodoTest.OTP.RecorderServer do
  @moduledoc false
  use Snodo.Server, name: "recorder-node", version: "0.1.0"
  import Snodo.OTP.Server

  alias SnodoTest.OTP.Recorder
  alias SnodoTest.OTP.RecorderContract

  expose(RecorderContract, target: Recorder)
end

defmodule SnodoTest.OTP.FaultyContract do
  @moduledoc false
  # CounterContract's server side, with client-side faults: arguments JSON
  # cannot encode, and a reply decode_reply does not match.
  @behaviour Snodo.OTP.Contract

  alias SnodoTest.OTP.CounterContract

  @impl true
  defdelegate ops(), to: CounterContract
  @impl true
  defdelegate build_message(name, args), to: CounterContract
  @impl true
  defdelegate encode_reply(name, reply), to: CounterContract

  @impl true
  def encode_call(:unencodable), do: {"counter_get", %{"x" => {1, 2}}}
  def encode_call(:undecodable), do: {"counter_add", %{"by" => 1}}
  def encode_call(message), do: CounterContract.encode_call(message)

  @impl true
  def encode_cast(:unencodable), do: {"counter_cast_add", %{"by" => {1, 2}}}
  def encode_cast(message), do: CounterContract.encode_cast(message)

  @impl true
  def decode_reply("counter_add", %{"total" => total}), do: total
  def decode_reply("counter_get" = name, json), do: CounterContract.decode_reply(name, json)
end
