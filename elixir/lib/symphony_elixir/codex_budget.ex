defmodule SymphonyElixir.CodexBudget do
  @moduledoc false

  @pricing_source_url "https://openai.com/api/pricing/"
  @model_pricing %{
    "gpt-5.4" => %{input_per_million: 2.50, cached_input_per_million: 0.25, output_per_million: 15.00}
  }

  @spec codex_info(SymphonyElixir.Config.Schema.t()) :: map()
  def codex_info(settings) do
    command = settings.codex.command
    model = extract_cli_flag_value(command, "--model") || "unknown"
    reasoning_effort = extract_config_value(command, "model_reasoning_effort") || "default"
    pricing = Map.get(@model_pricing, model)

    %{
      model: model,
      reasoning_effort: reasoning_effort,
      pricing_source_url: @pricing_source_url,
      pricing: pricing
    }
  end

  @spec estimated_cost_payload(map(), map()) :: map()
  def estimated_cost_payload(_tokens, %{pricing: nil}) do
    %{
      usd: nil,
      formatted: "n/a",
      note: "Pricing unavailable for the configured model"
    }
  end

  def estimated_cost_payload(tokens, %{pricing: pricing}) do
    input_tokens = Map.get(tokens, :input_tokens, 0)
    output_tokens = Map.get(tokens, :output_tokens, 0)

    usd =
      input_tokens * pricing.input_per_million / 1_000_000 +
        output_tokens * pricing.output_per_million / 1_000_000

    %{
      usd: Float.round(usd, 4),
      formatted: format_usd(usd),
      note: "Estimate based on uncached input/output pricing"
    }
  end

  @spec budget_exceeded?(map(), map(), SymphonyElixir.Config.Schema.t()) :: nil | map()
  def budget_exceeded?(tokens, codex_info, settings) do
    cost = estimated_cost_payload(tokens, codex_info)
    max_total_tokens = settings.codex.max_total_tokens
    max_estimated_cost_usd = settings.codex.max_estimated_cost_usd
    total_tokens = Map.get(tokens, :total_tokens, 0)

    cond do
      is_integer(max_total_tokens) and max_total_tokens > 0 and total_tokens > max_total_tokens ->
        %{
          kind: :max_total_tokens,
          message: "token budget exceeded: #{total_tokens} > #{max_total_tokens}",
          total_tokens: total_tokens,
          limit: max_total_tokens,
          estimated_cost: cost
        }

      is_number(max_estimated_cost_usd) and is_number(cost.usd) and cost.usd > max_estimated_cost_usd ->
        %{
          kind: :max_estimated_cost_usd,
          message: "cost budget exceeded: #{format_usd(cost.usd)} > #{format_usd(max_estimated_cost_usd)}",
          total_tokens: total_tokens,
          limit: max_estimated_cost_usd,
          estimated_cost: cost
        }

      true ->
        nil
    end
  end

  defp format_usd(usd) when is_number(usd), do: "$" <> :erlang.float_to_binary(usd, decimals: 2)
  defp format_usd(_usd), do: "n/a"

  defp extract_cli_flag_value(command, flag) when is_binary(command) and is_binary(flag) do
    regex = ~r/#{Regex.escape(flag)}(?:=|\s+)([^\s]+)/

    case Regex.run(regex, command, capture: :all_but_first) do
      [value] -> String.trim(value, ~s("'))
      _ -> nil
    end
  end

  defp extract_config_value(command, key) when is_binary(command) and is_binary(key) do
    regex = ~r/#{Regex.escape(key)}=([^\s]+)/

    case Regex.run(regex, command, capture: :all_but_first) do
      [value] -> String.trim(value, ~s("'))
      _ -> nil
    end
  end
end
