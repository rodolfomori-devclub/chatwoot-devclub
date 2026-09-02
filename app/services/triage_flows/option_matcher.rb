# Matches a customer reply against the options of one step.
#
# The same step is reached by very different inputs depending on the channel:
#   WhatsApp button/list tap -> a new incoming message whose content is the
#     option TITLE (the reply id is discarded, see
#     Whatsapp::IncomingMessageServiceHelpers#message_content)
#   Web widget               -> submitted_values.first['value'], the option ID
#   Typed text               -> the title, the id, or the 1-based index
#
# So every option is matched against all three candidates, normalised.
class TriageFlows::OptionMatcher
  class << self
    # Returns the matching Definition::Option, or nil.
    def match(step, raw)
      value = normalize(raw)
      return nil if value.blank?

      exact(step, value) || unique_prefix(step, value)
    end

    def normalize(value)
      I18n.transliterate(value.to_s).downcase.gsub(/[^a-z0-9]+/, ' ').strip
    end

    private

    def exact(step, value)
      step.options.each_with_index do |option, index|
        return option if candidates(option, index).include?(value)
      end
      nil
    end

    # "renov" -> Renovação, but only when exactly one option could be meant.
    def unique_prefix(step, value)
      return nil if value.length < 3

      hits = step.options.each_with_index.select do |option, index|
        candidates(option, index).any? { |c| c.start_with?(value) }
      end
      hits.one? ? hits.first.first : nil
    end

    def candidates(option, index)
      [normalize(option.id), normalize(option.title), (index + 1).to_s].reject(&:blank?)
    end
  end
end
