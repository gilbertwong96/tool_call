defmodule ToolCall.TestFixtures.Address do
  @moduledoc false
  @enforce_keys [:city]
  defstruct [:city, :street, country: "NO"]

  @type street :: String.t()
  @type t :: %__MODULE__{city: String.t(), street: street() | nil, country: String.t()}
end

defmodule ToolCall.TestFixtures.TreeNode do
  @moduledoc false
  defstruct [:value, children: []]

  @type t :: %__MODULE__{value: integer(), children: [t()]}
end

defmodule ToolCall.TestFixtures.OpaqueBox do
  @moduledoc false
  defstruct [:secret]

  @opaque t :: %__MODULE__{secret: String.t()}
end

defmodule ToolCall.TestFixtures.Partial do
  @moduledoc false
  defstruct [:a, :b, :c]

  @type t :: %__MODULE__{a: integer()}
end

defmodule ToolCall.TestFixtures.PrivateField do
  @moduledoc false
  defstruct [:hidden]

  @typep hidden :: String.t()
  @type t :: %__MODULE__{hidden: hidden()}
end

defmodule ToolCall.TestFixtures.FriendA do
  @moduledoc false
  defstruct [:b]

  @type t :: %__MODULE__{b: ToolCall.TestFixtures.FriendB.t() | nil}
end

defmodule ToolCall.TestFixtures.FriendB do
  @moduledoc false
  defstruct [:a]

  @type t :: %__MODULE__{a: ToolCall.TestFixtures.FriendA.t() | nil}
end

defmodule ToolCall.TestFixtures.PathNode do
  @moduledoc false
  defstruct [:head, :tail]

  @type path :: %{head: integer(), tail: path() | nil}
  @type t :: %__MODULE__{head: integer(), tail: path() | nil}
end

defmodule ToolCall.TestFixtures.NoType do
  @moduledoc false
  defstruct [:x]
end

defmodule ToolCall.TestFixtures.WeirdType do
  @moduledoc false
  defstruct [:x]

  @type t :: String.t()
end

defmodule ToolCall.TestFixtures.Shapes do
  @moduledoc false
  defstruct [:pair, :map]

  @type t :: %__MODULE__{
          pair: {ToolCall.TestFixtures.Address.t(), integer()},
          map: %{a: ToolCall.TestFixtures.Address.t()}
        }
end

defmodule ToolCall.TestFixtures.ParamOnly do
  @moduledoc false
  defstruct [:a]

  @type t(a) :: %__MODULE__{a: a}
end

defmodule ToolCall.TestFixtures.Deep do
  @moduledoc false
  defstruct [:v]

  @type t0 :: {t1(), t1()}
  @type t1 :: {t2(), t2()}
  @type t2 :: {t3(), t3()}
  @type t3 :: {t4(), t4()}
  @type t4 :: {t5(), t5()}
  @type t5 :: {t6(), t6()}
  @type t6 :: {t7(), t7()}
  @type t7 :: integer()
  @type t :: %__MODULE__{v: t0()}
end

defmodule ToolCall.TestFixtures.ChainHost do
  @moduledoc false
  defstruct [:node]

  @type chain :: %{node: ToolCall.TestFixtures.Address.t(), next: chain() | nil}
  @type t :: %__MODULE__{node: chain()}
end

defmodule ToolCall.TestFixtures.NotAStruct do
  @moduledoc false
  @type t :: String.t()
end
