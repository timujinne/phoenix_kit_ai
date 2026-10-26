defmodule PhoenixKitAI.BudgetMonthlyTest do
  @moduledoc "The site-wide monthly spend cap (`ai_monthly_cap`), through the public verbs."

  use PhoenixKitAI.DataCase, async: false

  alias PhoenixKitAI.{Budget, Errors, GuardEvent, Request, RequestCache, TaskLimits}
  alias PhoenixKitAI.Test.Repo, as: TestRepo

  # Far east of UTC, so the local month starts hours before the UTC one.
  @zone "Pacific/Auckland"

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options,
      plug: {Req.Test, PhoenixKitAI.BudgetMonthlyTest},
      retry: false
    )

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    {:ok, _} = PhoenixKit.Settings.update_setting("time_zone", @zone)
    reset()

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ai, :req_options)
      reset()
    end)

    {:ok, endpoint: endpoint_fixture()}
  end

  defp reset do
    RequestCache.clear()
    Budget.reset_warnings()

    for scope <- [:global, :global_month, :endpoint, :user, :user_calls],
        do: {:ok, _} = Budget.set_limit(scope, 0)

    {:ok, _} =
      PhoenixKit.Settings.update_setting_with_module("ai_budget_warn_percent", "80", "ai")
  end

  defp endpoint_fixture do
    {:ok, ep} =
      PhoenixKitAI.create_endpoint(%{
        name: "Month-EP-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "google/gemini-2.5-flash",
        api_key: "sk-test-key"
      })

    ep
  end

  defp stub_chat(test_pid, cost \\ 0.5) do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, _raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, :provider_called)

      Req.Test.json(conn, %{
        "choices" => [%{"message" => %{"role" => "assistant", "content" => "42"}}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => cost}
      })
    end)
  end

  defp month_start, do: TaskLimits.windows().month |> elem(0)

  # A usage row written at `at`, `cost` dollars.
  defp usage_row(endpoint, at, cost, status \\ "success") do
    at = DateTime.truncate(at, :second)

    %Request{
      endpoint_uuid: endpoint.uuid,
      endpoint_name: endpoint.name,
      model: endpoint.model,
      request_type: "chat",
      status: status,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cost: Decimal.new(cost),
      latency_ms: 1,
      metadata: %{},
      inserted_at: at,
      updated_at: at
    }
    |> TestRepo.insert!()
  end

  defp month_status(ep) do
    Enum.find(Budget.status(ep, []), &(&1.scope == :global_month))
  end

  defp dollars?(%Decimal{} = value, expected), do: Decimal.equal?(value, Decimal.new(expected))
  defp dollars?(_value, _expected), do: false

  defp attach(event) do
    :telemetry.attach(
      "#{inspect(event)}-#{System.unique_integer([:positive])}",
      event,
      fn e, m, meta, pid -> send(pid, {:event, e, m, meta}) end,
      self()
    )
  end

  describe "the setting" do
    test "ai_monthly_cap holds dollars, like the daily caps" do
      assert Budget.setting(:global_month) == "ai_monthly_cap"

      assert {:ok, _} = Budget.set_limit(:global_month, "100")
      assert PhoenixKit.Settings.get_setting("ai_monthly_cap") == "100.00"
      assert dollars?(Budget.limit(:global_month), "100")

      assert {:error, :ambiguous_amount} = Budget.set_limit(:global_month, 5_000_000)
      assert {:error, :invalid_amount} = Budget.set_limit(:global_month, "-1")
      assert {:error, :invalid_amount} = Budget.set_limit(:global_month, "lots")
      assert dollars?(Budget.limit(:global_month), "100")
    end

    test "0 and blank mean no cap, and garbage is read as no cap", %{endpoint: ep} do
      for value <- ["0", "0.00", "", "  ", "lots"] do
        {:ok, _} = PhoenixKit.Settings.update_setting_with_module("ai_monthly_cap", value, "ai")
        assert dollars?(Budget.limit(:global_month), "0")
        assert month_status(ep) == nil
      end

      stub_chat(self())
      usage_row(ep, DateTime.utc_now(), "1000.00")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")
    end
  end

  describe "the check" do
    test "a cap reached this month refuses before the provider, cached answers too", %{
      endpoint: ep
    } do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "1.00")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1")
      assert_received :provider_called
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q2")
      assert_received :provider_called

      assert %{spent: spent, remaining: remaining} = month_status(ep)
      assert dollars?(spent, "1") and dollars?(remaining, "0")

      assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "q3")
      refute_received :provider_called

      assert {:error, {:budget_exceeded, :global_month}} =
               PhoenixKitAI.ask(ep.uuid, "q1", cache: true)

      refute_received :provider_called
    end

    test "under the cap the call goes through", %{endpoint: ep} do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "100")
      usage_row(ep, DateTime.utc_now(), "99.00")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")
      assert_received :provider_called
    end

    test "spend from before the local month start does not count, the first instant does", %{
      endpoint: ep
    } do
      from = month_start()
      {:ok, _} = Budget.set_limit(:global_month, "1.00")

      usage_row(ep, DateTime.add(from, -1, :second), "5.00")
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "0")

      usage_row(ep, from, "0.40")
      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "0.4")

      stub_chat(self())
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")
    end

    test "a month is longer than the rolling day the other caps look at", %{endpoint: ep} do
      # Rows from days ago in this month count for the monthly cap only; the
      # window starts at the local month start, so skip when it is today.
      from = month_start()
      old = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)

      if DateTime.compare(old, from) == :gt do
        {:ok, _} = Budget.set_limit(:global, "1.00")
        {:ok, _} = Budget.set_limit(:global_month, "1.00")
        usage_row(ep, old, "2.00")

        assert [%{scope: :global, spent: day}, %{scope: :global_month, spent: month}] =
                 Budget.status(ep, [])

        assert dollars?(day, "0") and dollars?(month, "2")
        stub_chat(self())

        assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "q")
        refute_received :provider_called
      end
    end

    test "failed calls do not count", %{endpoint: ep} do
      {:ok, _} = Budget.set_limit(:global_month, "1.00")
      usage_row(ep, DateTime.utc_now(), "5.00", "error")

      assert %{spent: spent} = month_status(ep)
      assert dollars?(spent, "0")

      stub_chat(self())
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q")
    end

    test "the daily cap still decides on its own", %{endpoint: ep} do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global, "0.50")
      {:ok, _} = Budget.set_limit(:global_month, "100")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1")
      assert {:error, {:budget_exceeded, :global}} = PhoenixKitAI.ask(ep.uuid, "q2")
      assert [%{scope: :global}, %{scope: :global_month}] = Budget.status(ep, [])
    end

    test "the refusal is a guard event of scope budget:global_month", %{endpoint: ep} do
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "0.50")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "q1")
      assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "q2")

      assert [%GuardEvent{ref: %{"scope" => "budget:global_month"}}] =
               TestRepo.all(from(e in GuardEvent, where: e.kind == "limit_reached"))
    end

    test "the warning fires once per crossing, with the scope in its metadata", %{endpoint: ep} do
      attach([:phoenix_kit_ai, :budget, :warning])
      stub_chat(self())
      {:ok, _} = Budget.set_limit(:global_month, "1.20")

      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "1")
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "2")
      refute_received {:event, _, _, _}
      # $1.00 of $1.20 = 83%: one warning on the next check, then none.
      assert {:ok, _} = PhoenixKitAI.ask(ep.uuid, "3")
      assert_received {:event, _, %{spent: 1.0, limit: 1.2}, %{scope: :global_month}}
      refute_received {:event, _, _, _}
      assert {:error, {:budget_exceeded, :global_month}} = PhoenixKitAI.ask(ep.uuid, "4")
      refute_received {:event, _, _, _}
    end
  end

  describe "the refusal text" do
    test "names the month and is translated" do
      assert Errors.message({:budget_exceeded, :global_month}) ==
               "The AI budget for this month has been used up"

      for locale <- ["et", "ru"] do
        Gettext.with_locale(PhoenixKitAI.Gettext, locale, fn ->
          refute Errors.message({:budget_exceeded, :global_month}) =~ "this month",
                 "#{locale} fell back to English"
        end)
      end
    end
  end
end
