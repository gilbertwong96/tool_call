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

defmodule ToolCall.TestFixtures.NotAStruct do
  @moduledoc false
  @type t :: String.t()
end
