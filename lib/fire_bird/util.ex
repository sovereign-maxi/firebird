defmodule FireBird.Util do
  @moduledoc false

  @doc """
  Parses a value into an integer.

  Handles integers, floats (truncated), and numeric strings.
  Returns `{:ok, integer}` or `:error`.
  """
  @spec parse_integer(term()) :: {:ok, integer()} | :error
  def parse_integer(val) when is_integer(val), do: {:ok, val}
  def parse_integer(val) when is_float(val), do: {:ok, trunc(val)}

  def parse_integer(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> {:ok, int}
      _trailing_garbage -> :error
    end
  end

  def parse_integer(_val), do: :error

  @doc """
  Validates that `val` is a positive integer.

  Raises `ArgumentError` with a message including the `caller` module name
  and `name` of the option that failed validation.
  """
  @spec validate_positive!(String.t(), atom(), term()) :: :ok
  def validate_positive!(_caller, _name, val) when is_integer(val) and val > 0, do: :ok

  def validate_positive!(caller, name, val) do
    raise ArgumentError,
          "#{caller}: #{name} must be a positive integer, got: #{inspect(val)}"
  end
end
