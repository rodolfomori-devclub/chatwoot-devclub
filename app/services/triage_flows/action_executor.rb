# Applies a terminal Route: lands the conversation where the flow says it
# should go and closes the session.
#
# Reached from three places — a matched option, the no_match fallback and
# TriageFlows::TimeoutJob — which is why the closing status is a parameter.
class TriageFlows::ActionExecutor
  def initialize(session)
    @session = session
  end

  def call(route, status: :completed)
    outcome = outcome_for(route)
    shadow? ? log_shadow(route, outcome) : apply(route, outcome)
    finish(route, outcome, status)
  end

  private

  attr_reader :session

  delegate :conversation, to: :session

  def shadow?
    session.mode == 'shadow'
  end

  # Shadow mode changes nothing: the decision is kept in the trace and the log
  # so a flow can be watched in production before it is switched on.
  def log_shadow(route, outcome)
    Rails.logger.info(
      "[triage][shadow] session=#{session.id} conversation=#{conversation.id} route=#{outcome} message=#{route.message.inspect}"
    )
  end

  def apply(route, outcome)
    land_conversation(outcome)
    conversation.add_labels(route.labels)
    send_message(route)
    # The only line a live route leaves in the log. Without it the first hour of
    # a cutover is readable from the database alone.
    Rails.logger.info("[triage] session=#{session.id} conversation=#{conversation.id} route=#{outcome}")
  end

  # One write for the routing fields. `open` on a pending conversation goes
  # through bot_handoff! instead, so CONVERSATION_BOT_HANDOFF still fires for
  # whatever picks the conversation up next.
  def land_conversation(outcome)
    handoff = outcome['status'] == 'open' && conversation.pending?
    attributes = { team_id: outcome['team_id'], status: (outcome['status'] unless handoff) }.compact
    conversation.update!(attributes) if attributes.present?
    conversation.bot_handoff! if handoff
  end

  def send_message(route)
    return if route.message.blank?
    # Outside the WhatsApp 24h window the send would only fail.
    return unless conversation.can_reply?

    conversation.messages.create!(account_id: conversation.account_id, inbox_id: conversation.inbox_id,
                                  message_type: :template, content_type: 'text', content: route.message)
  end

  def finish(route, outcome, status)
    session.trace!(:route, outcome: outcome, message: route.message, shadow: shadow?)
    session.status = status
    session.outcome = outcome
    session.finished_at = Time.current
    session.timeout_token = nil
    session.save!
  end

  def outcome_for(route)
    { 'team_id' => routable_team_id(route), 'labels' => route.labels, 'status' => route.status }
  end

  # The team is validated when the flow is saved, but it can be deleted while
  # sessions are in flight; a dangling id must not break the routing.
  def routable_team_id(route)
    return nil if route.team_id.blank?

    route.team_id if conversation.account.teams.exists?(id: route.team_id)
  end
end
