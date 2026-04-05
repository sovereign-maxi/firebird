defmodule FireBird.CleanerTest do
  use ExUnit.Case, async: false

  alias FireBird.Cleaner

  setup do
    n = System.unique_integer([:positive])
    table = :"dedup_cleaner_test_#{n}"
    :ets.new(table, [:named_table, :set, :public])
    %{table: table}
  end

  describe "cleanup/2" do
    test "deletes entries older than TTL", %{table: table} do
      # Insert an entry that looks old (well before now - ttl)
      old_ts = System.monotonic_time(:millisecond) - 200_000
      :ets.insert(table, {"old_hash", old_ts})

      deleted = Cleaner.cleanup(table, 100_000)
      assert deleted == 1
      assert :ets.lookup(table, "old_hash") == []
    end

    test "retains entries within TTL", %{table: table} do
      recent_ts = System.monotonic_time(:millisecond)
      :ets.insert(table, {"recent_hash", recent_ts})

      deleted = Cleaner.cleanup(table, 100_000)
      assert deleted == 0
      assert :ets.lookup(table, "recent_hash") != []
    end

    test "handles non-existent table" do
      assert Cleaner.cleanup(:nonexistent_table_xyz, 100_000) == 0
    end

    test "mixed: old entries deleted, recent entries retained", %{table: table} do
      now = System.monotonic_time(:millisecond)
      :ets.insert(table, {"old_1", now - 300_000})
      :ets.insert(table, {"old_2", now - 250_000})
      :ets.insert(table, {"recent_1", now - 10_000})
      :ets.insert(table, {"recent_2", now})

      deleted = Cleaner.cleanup(table, 100_000)
      assert deleted == 2
      assert :ets.lookup(table, "old_1") == []
      assert :ets.lookup(table, "old_2") == []
      assert :ets.lookup(table, "recent_1") != []
      assert :ets.lookup(table, "recent_2") != []
    end
  end

  describe "cleanup_rate_limit/2" do
    test "deletes rate limit entries older than TTL" do
      n = System.unique_integer([:positive])
      rl_table = :"rate_limit_test_#{n}"
      :ets.new(rl_table, [:named_table, :set, :public])

      old_ts = System.monotonic_time(:millisecond) - 200_000
      :ets.insert(rl_table, {"192.168.1.1", 5, old_ts})

      deleted = Cleaner.cleanup_rate_limit(rl_table, 100_000)
      assert deleted == 1
      assert :ets.lookup(rl_table, "192.168.1.1") == []
    end

    test "retains rate limit entries within TTL" do
      n = System.unique_integer([:positive])
      rl_table = :"rate_limit_retain_#{n}"
      :ets.new(rl_table, [:named_table, :set, :public])

      recent_ts = System.monotonic_time(:millisecond)
      :ets.insert(rl_table, {"10.0.0.1", 3, recent_ts})

      deleted = Cleaner.cleanup_rate_limit(rl_table, 100_000)
      assert deleted == 0
      assert :ets.lookup(rl_table, "10.0.0.1") != []
    end

    test "handles non-existent table" do
      assert Cleaner.cleanup_rate_limit(:nonexistent_rl_table_xyz, 100_000) == 0
    end
  end

  describe "periodic cleanup" do
    test "runs on schedule with short interval", %{table: table} do
      now = System.monotonic_time(:millisecond)
      :ets.insert(table, {"stale", now - 200_000})

      n = System.unique_integer([:positive])

      start_supervised!(
        {Cleaner,
         [
           dedup_table: table,
           ttl_ms: 100_000,
           interval_ms: 50,
           name: :"dedup_cleaner_#{n}"
         ]}
      )

      # Poll until the cleanup tick deletes the stale entry
      FireBirdHelpers.await_condition(fn ->
        :ets.lookup(table, "stale") == []
      end)

      assert :ets.lookup(table, "stale") == []
    end

    test "also cleans rate limit table on schedule" do
      n = System.unique_integer([:positive])
      dedup_table = :"dedup_sched_#{n}"
      rl_table = :"rl_sched_#{n}"
      :ets.new(dedup_table, [:named_table, :set, :public])
      :ets.new(rl_table, [:named_table, :set, :public])

      now = System.monotonic_time(:millisecond)
      :ets.insert(dedup_table, {"old_hash", now - 200_000})
      :ets.insert(rl_table, {"1.2.3.4", 10, now - 200_000})

      start_supervised!(
        {Cleaner,
         [
           dedup_table: dedup_table,
           rate_limit_table: rl_table,
           ttl_ms: 100_000,
           interval_ms: 50,
           name: :"dedup_cleaner_rl_#{n}"
         ]}
      )

      # Poll until the cleanup tick deletes both stale entries
      FireBirdHelpers.await_condition(fn ->
        :ets.lookup(dedup_table, "old_hash") == [] and
          :ets.lookup(rl_table, "1.2.3.4") == []
      end)

      assert :ets.lookup(dedup_table, "old_hash") == []
      assert :ets.lookup(rl_table, "1.2.3.4") == []
    end
  end
end
