# Sends the menu message for one step of a flow.
#
# The message is built by hand rather than through Messages::MessageBuilder,
# which overwrites content_attributes and would drop the triage marker the
# widget reply is matched against. It is typed :template so human_response?
# and valid_first_reply? stay false and the bot never counts as a first reply.
#
# WhatsApp turns the items into reply buttons (<= 3 options) or a list on its
# own. Channels that cannot render input_select get the same options as a
# numbered list the customer answers by typing "2".
class TriageFlows::PromptSender
  SELECT_CHANNELS = ['Channel::Whatsapp', 'Channel::WebWidget', 'Channel::Api'].freeze

  def initialize(session)
    @session = session
  end

  # Returns the created Message.
  def call(step, prefix: nil)
    conversation.messages.create!(
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :template,
      content_type: content_type,
      content: content(step, prefix),
      content_attributes: content_attributes(step)
    )
  end

  private

  attr_reader :session

  delegate :conversation, to: :session

  def select_capable?
    SELECT_CHANNELS.include?(conversation.inbox.channel_type)
  end

  def content_type
    select_capable? ? 'input_select' : 'text'
  end

  def content(step, prefix)
    body = [prefix, step.prompt].compact_blank.join("\n\n")
    return body if select_capable?

    [body, numbered_options(step)].join("\n\n")
  end

  def numbered_options(step)
    step.options.each_with_index.map { |option, index| "#{index + 1}. #{option.title}" }.join("\n")
  end

  # Only :title and :value are allowed inside items (ContentAttributeValidator);
  # the triage marker sits at the top level, which is unconstrained.
  def content_attributes(step)
    attributes = { triage: marker(step) }
    attributes[:items] = step.options.map { |option| { title: option.title, value: option.id } } if select_capable?
    attributes
  end

  def marker(step)
    {
      flow_id: session.triage_flow_id,
      session_id: session.id,
      step_id: step.id,
      version: session.flow_version
    }
  end
end
