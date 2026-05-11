module BetterStackWarehouse
  # Cost-at-emission rates. Costs are computed at the time the event is
  # emitted and recorded into the warehouse so historical aggregates reflect
  # the price the operator was actually charged. Raw token / character counts
  # are also emitted so analytics can recompute against future rates if
  # needed.
  module Pricing
    # Anthropic - Claude Sonnet 4 (claude-sonnet-4-20250514).
    # Source: https://platform.claude.com/docs/en/docs/about-claude/pricing (2026-05-11).
    CLAUDE_SONNET_4_INPUT_PER_MTOK  = 3.00
    CLAUDE_SONNET_4_OUTPUT_PER_MTOK = 15.00

    # OpenAI - GPT-4o.
    # Source: https://openai.com/api/pricing/ (2026-05-11).
    GPT_4O_INPUT_PER_MTOK  = 2.50
    GPT_4O_OUTPUT_PER_MTOK = 10.00

    # DeepL Pro API - per character.
    # TODO(verify): the DeepL Help Center pricing page returned 403 from the
    # workstation used to seed this constant; secondary sources gave
    # conflicting figures ($25/M chars and $5.49/M chars). $25/M is the
    # conservative (higher) figure. Confirm against the DeepL billing portal
    # for this account before relying on translation_cost_usd for budgeting.
    DEEPL_PER_MCHAR = 25.00

    def self.claude_sonnet_4(tokens_in:, tokens_out:)
      ((tokens_in.to_i * CLAUDE_SONNET_4_INPUT_PER_MTOK) +
       (tokens_out.to_i * CLAUDE_SONNET_4_OUTPUT_PER_MTOK)) / 1_000_000.0
    end

    def self.gpt_4o(tokens_in:, tokens_out:)
      ((tokens_in.to_i * GPT_4O_INPUT_PER_MTOK) +
       (tokens_out.to_i * GPT_4O_OUTPUT_PER_MTOK)) / 1_000_000.0
    end

    def self.deepl(chars:)
      chars.to_i * DEEPL_PER_MCHAR / 1_000_000.0
    end
  end
end
