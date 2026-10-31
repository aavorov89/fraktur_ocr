module BetterStackWarehouse
  # Cost-at-emission rates. Costs are computed at the time the event is
  # emitted and recorded into the warehouse so historical aggregates reflect
  # the price the operator was actually charged. Raw token / character counts
  # are also emitted so analytics can recompute against future rates if
  # needed.
  module Pricing
    # USD per million tokens, [input, output], keyed by the model id the API
    # reports.
    # Anthropic source: https://platform.claude.com/docs/en/docs/about-claude/pricing (2026-10-20).
    # OpenAI source: https://openai.com/api/pricing/ (2026-10-20).
    TOKEN_RATES_PER_MTOK = {
      "claude-opus-5-5"   => [4.00, 20.00],
      "claude-sonnet-5-5" => [2.00, 10.00],
      "claude-haiku-5-5"  => [0.10, 0.50],
      "gpt-5.2"           => [1.75, 14.00],
      "gpt-4o"            => [2.50, 10.00]
    }.freeze

    # DeepL Pro API - per character.
    # TODO(verify): the DeepL Help Center pricing page returned 403 from the
    # workstation used to seed this constant; secondary sources gave
    # conflicting figures ($25/M chars and $5.49/M chars). $25/M is the
    # conservative (higher) figure. Confirm against the DeepL billing portal
    # for this account before relying on translation_cost_usd for budgeting.
    DEEPL_PER_MCHAR = 25.00

    # Cost of one request, or nil for a model without a known rate (so a new
    # model never gets silently priced at an old model's rate).
    def self.tokens(model, tokens_in:, tokens_out:)
      rate_in, rate_out = TOKEN_RATES_PER_MTOK[model.to_s]
      return nil unless rate_in

      ((tokens_in.to_i * rate_in) + (tokens_out.to_i * rate_out)) / 1_000_000.0
    end

    def self.deepl(chars:)
      chars.to_i * DEEPL_PER_MCHAR / 1_000_000.0
    end
  end
end
