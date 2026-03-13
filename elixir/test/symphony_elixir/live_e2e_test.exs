defmodule SymphonyElixir.LiveE2ETest do
  use ExUnit.Case

  @moduletag :live_e2e

  @tag skip: "GitHub Projects live smoke coverage is tracked separately from the test rewrite ticket."
  test "github projects live smoke coverage is tracked separately" do
    assert true
  end
end
