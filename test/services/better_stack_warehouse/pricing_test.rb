require "test_helper"

class BetterStackWarehouse::PricingTest < ActiveSupport::TestCase
  test "claude sonnet 4 cost at $3 in / $15 out per million" do
    cost = BetterStackWarehouse::Pricing.claude_sonnet_4(tokens_in: 1_000_000, tokens_out: 1_000_000)
    assert_in_delta 18.0, cost, 1e-9
  end

  test "gpt-4o cost at $2.50 in / $10 out per million" do
    cost = BetterStackWarehouse::Pricing.gpt_4o(tokens_in: 1_000_000, tokens_out: 1_000_000)
    assert_in_delta 12.5, cost, 1e-9
  end

  test "deepl per-character pricing matches the constant" do
    cost = BetterStackWarehouse::Pricing.deepl(chars: 1_000_000)
    assert_in_delta BetterStackWarehouse::Pricing::DEEPL_PER_MCHAR, cost, 1e-9
  end

  test "nil token counts are treated as zero" do
    cost = BetterStackWarehouse::Pricing.claude_sonnet_4(tokens_in: nil, tokens_out: nil)
    assert_equal 0.0, cost
  end
end
