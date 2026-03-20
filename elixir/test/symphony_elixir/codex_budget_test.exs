defmodule SymphonyElixir.CodexBudgetTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CodexBudget
  alias SymphonyElixir.Config.Schema

  test "estimates GPT-5.4 cost and trips configured budgets" do
    settings = %Schema{
      codex: %Schema.Codex{
        command: "codex --config model_reasoning_effort=high --model gpt-5.4 app-server",
        max_total_tokens: 1_500_000,
        max_estimated_cost_usd: 5.0
      }
    }

    codex_info = CodexBudget.codex_info(settings)

    assert codex_info.model == "gpt-5.4"
    assert codex_info.reasoning_effort == "high"

    cost =
      CodexBudget.estimated_cost_payload(
        %{input_tokens: 1_000_000, output_tokens: 10_000, total_tokens: 1_010_000},
        codex_info
      )

    assert cost.formatted == "$2.65"

    assert %{kind: :max_total_tokens} =
             CodexBudget.budget_exceeded?(
               %{input_tokens: 1_490_000, output_tokens: 20_000, total_tokens: 1_510_000},
               codex_info,
               settings
             )

    assert %{kind: :max_estimated_cost_usd} =
             CodexBudget.budget_exceeded?(
               %{input_tokens: 1_900_000, output_tokens: 20_000, total_tokens: 1_920_000},
               codex_info,
               %{settings | codex: %{settings.codex | max_total_tokens: 10_000_000}}
             )
  end
end
