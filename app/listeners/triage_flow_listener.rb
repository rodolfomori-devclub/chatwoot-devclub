# Drives the per-inbox triage flow.
#
# Deliberately hooks message_created and NOT conversation_created: on WhatsApp
# the conversation and its first message are created inside one transaction
# (Whatsapp::IncomingMessageBaseService#process_messages) and both events are
# enqueued after the same commit with no ordering guarantee. Starting the flow
# on conversation_created would race the first message and score the customer's
# "oi" as a wrong answer.
#
# Runs inside EventDispatcherJob, so a failure here can never break the
# incoming webhook or the widget request.
class TriageFlowListener < BaseListener
  def message_created(event)
    message = event.data[:message]
    return unless actionable?(event, message)

    flow = active_flow_for(message.conversation)
    return if flow.blank?

    runner = TriageFlows::Runner.new(flow, message.conversation)
    if message.incoming?
      runner.incoming(message)
    elsif agent_reply?(message)
      runner.agent_took_over(message)
    end
  end

  # The web widget answers by PATCHing submitted_values onto the menu message
  # itself rather than creating a new incoming message.
  def message_updated(event)
    message = event.data[:message]
    return unless actionable?(event, message)
    return unless message.content_type == 'input_select'
    return if message.content_attributes['triage'].blank?

    value = newly_submitted_value(event)
    return if value.blank?

    flow = active_flow_for(message.conversation)
    return if flow.blank?

    TriageFlows::Runner.new(flow, message.conversation).widget_reply(message, value)
  end

  private

  def actionable?(event, message)
    return false if message.blank?
    return false if performed_by_triage_flow?(event)
    return false if message.private? || message.activity?

    message.conversation.present?
  end

  # Our own writes must not re-enter the engine. Mirrors the guard in
  # AutomationRuleListener#performed_by_automation?.
  def performed_by_triage_flow?(event)
    event.data[:performed_by].is_a?(TriageFlow)
  end

  def agent_reply?(message)
    message.outgoing? && message.sender.is_a?(User)
  end

  def active_flow_for(conversation)
    return nil unless conversation.account.feature_enabled?('triage_flows')

    flow = conversation.inbox.triage_flow
    flow&.enabled? ? flow : nil
  end

  # Only the first click counts: submitted_values going from blank to present.
  # Message#send_update_event ships `previous_changes`, i.e. [before, after].
  def newly_submitted_value(event)
    before, after = event.data[:previous_changes].to_h['content_attributes']
    return nil if after.blank?

    submitted = after['submitted_values']
    return nil if submitted.blank?
    return nil if before.present? && before['submitted_values'].present?

    submitted.first['value']
  end
end
