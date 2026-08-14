defmodule FireBird.UtilTest do
  use ExUnit.Case, async: true

  alias FireBird.Util

  describe "parse_integer/1" do
    test "passes through integers" do
      assert {:ok, 42} = Util.parse_integer(42)
      assert {:ok, 0} = Util.parse_integer(0)
      assert {:ok, -1} = Util.parse_integer(-1)
    end

    test "truncates floats" do
      assert {:ok, 5} = Util.parse_integer(5.8)
      assert {:ok, 0} = Util.parse_integer(0.9)
    end

    test "parses numeric strings" do
      assert {:ok, 10} = Util.parse_integer("10")
      assert {:ok, 0} = Util.parse_integer("0")
    end

    test "returns error for non-numeric strings" do
      assert :error = Util.parse_integer("garbage")
      assert :error = Util.parse_integer("")
    end

    test "rejects strings with trailing content (full consumption required)" do
      assert :error = Util.parse_integer("123.45")
      assert :error = Util.parse_integer("42abc")
      assert :error = Util.parse_integer("100 sats")
    end

    test "returns error for unsupported types" do
      assert :error = Util.parse_integer(nil)
      assert :error = Util.parse_integer(:atom)
      assert :error = Util.parse_integer([1])
    end
  end

  describe "validate_positive!/3" do
    test "accepts positive integers" do
      assert :ok = Util.validate_positive!("Test", :field, 1)
      assert :ok = Util.validate_positive!("Test", :field, 100)
    end

    test "rejects zero" do
      assert_raise ArgumentError, ~r/field must be a positive integer/, fn ->
        Util.validate_positive!("Test", :field, 0)
      end
    end

    test "rejects negative integers" do
      assert_raise ArgumentError, ~r/field must be a positive integer/, fn ->
        Util.validate_positive!("Test", :field, -1)
      end
    end

    test "includes caller in error message" do
      assert_raise ArgumentError, ~r/^MyModule:/, fn ->
        Util.validate_positive!("MyModule", :count, 0)
      end
    end
  end
end
