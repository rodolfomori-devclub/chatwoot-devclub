# The triage engine: turns one customer reply into the next prompt or a
# terminal route.
#
# Only TriageFlowListener drives it, so the feature flag, the inbox flow and
# "is this message one of ours" have already been checked. Every entry point
# takes the session row lock, stamps Current.executed_by with the flow so our
# own writes skip the listener, and swallows its own errors: this runs inside
# EventDispatcherJob, where a raise would retry the whole event fan-out.
class TriageFlows::Runner
  # How many questions one customer may walk through before the flow gives up
  # and hands them to the no-match landing. Generous for any real tree; the
  # point is that a cycle terminates.
  MAX_TRANSITIONS = 20

  def initialize(flow, conversation)
    @flow = flow
    @conversation = conversation
  end

  def incoming(message)
    guarded do
      session = session_for
      session.present? ? answer(session, message) : start(message)
    end
  end

  # The web widget answers by PATCHing submitted_values onto the menu message
  # itself, so the "message" here is our own prompt, not a customer message.
  def widget_reply(message, value)
    guarded do
      session = session_for
      next if session.blank?

      session.with_lock { reply_to_prompt(session, message, value) }
    end
  end

  def agent_took_over(message)
    guarded do
      session = session_for
      next if session.blank?

      session.with_lock { abandon(session, message) }
    end
  end

  private

  attr_reader :flow, :conversation

  # Only executed_by is ours to touch: this runs inside the shared listener
  # fan-out of EventDispatcherJob, where Current.user and Current.contact
  # belong to whoever set them.
  def guarded
    previous = Current.executed_by
    Current.executed_by = flow
    yield
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: conversation.account).capture_exception
  ensure
    Current.executed_by = previous
  end

  def definition
    flow.parsed
  end

  def session_for
    TriageSession.find_by(conversation_id: conversation.id)
  end

  # Shadow mode is decided by the session, not the flow: a session that started
  # in shadow stays in shadow even if the flow is flipped to live mid-menu.
  def shadow?(session)
    session.mode == 'shadow'
  end

  def start(message)
    return unless startable?(message)

    entry = definition.entry_step
    return if entry.blank?

    # reload first: a conversation created in this same request still carries
    # the display_id its DB trigger filled in, and lock! refuses a dirty record.
    conversation.reload.with_lock do
      session = open_session
      next if session.blank?

      hand_over_to_flow(session)
      send_prompt(session, entry, message)
    end
  end

  # Only the opening message of a conversation nobody has touched starts a flow.
  def startable?(message)
    return false if conversation.campaign_id.present?
    return false if conversation.contact.blocked?
    return false if conversation.messages.incoming.exists?(['id < ?', message.id])

    conversation.messages.outgoing.where(private: false, sender_type: 'User').none?
  end

  # nil when another message won the race: the unique index on conversation_id
  # turns the loser into a find, and only the creator prompts.
  def open_session
    session = TriageSession.create_or_find_by!(conversation_id: conversation.id) do |new_session|
      new_session.account_id = conversation.account_id
      new_session.triage_flow_id = flow.id
      new_session.flow_version = flow.version
      new_session.mode = flow.mode
    end
    return nil unless session.previously_new_record?

    session.conversation = conversation
    session
  end

  # On an inbox without a bot the conversation is already open and
  # AutoAssignmentHandler has already picked an agent, so both are undone.
  def hand_over_to_flow(session)
    return if shadow?(session)

    conversation.update!(assignee_id: nil, status: :pending)
  end

  def answer(session, message)
    return if session.terminal?

    session.with_lock do
      next if session.terminal?
      next unless answerable?(session, message)

      session.last_input_message_id = message.id
      handle_input(session, message.content, message, source: 'message')
    end
  end

  # Anything at or before the prompt is history: the message that opened the
  # conversation, a Sidekiq retry, or the reply we already scored.
  def answerable?(session, message)
    message.id > session.last_prompt_message_id.to_i && message.id != session.last_input_message_id
  end

  def reply_to_prompt(session, message, value)
    unless current_prompt?(session, message)
      session.trace!(:stale, message_id: message.id, step_id: session.current_step_id)
      return session.save!
    end

    handle_input(session, value, message, source: 'submitted_values')
  end

  # The widget can PATCH any menu it has ever rendered; only the one we are
  # waiting on counts.
  def current_prompt?(session, message)
    session.active? &&
      message.id == session.last_prompt_message_id &&
      message.content_attributes.dig('triage', 'step_id') == session.current_step_id
  end

  # The agent is talking to the customer now, so the menu is over. The
  # conversation has to come back out of `pending` in the same breath: the
  # scheduled TimeoutJob is disarmed by clearing the token, and nothing else
  # ever looks at a session that is no longer active.
  def abandon(session, message)
    TriageFlows::SessionReleaser.new(session).call(:agent_took_over, message_id: message.id)
  end

  def handle_input(session, raw, trigger, source:)
    step = definition.step(session.current_step_id)
    return step_deleted(session, source) if step.blank?

    option = TriageFlows::OptionMatcher.match(step, raw)
    session.trace!(:input, step_id: step.id, source: source, input: raw.to_s.truncate(80), option_id: option&.id)
    return no_match(session, step, trigger) if option.blank?

    session.attempts = 0
    session.record_step(step.id, input: raw.to_s, option_id: option.id)
    follow(session, option.next, trigger)
  end

  def follow(session, transition, trigger)
    case transition
    when TriageFlows::Definition::StepRef
      return hop_limit(session) if session.path.length >= MAX_TRANSITIONS

      step = definition.step(transition.step_id)
      send_prompt(session, step, trigger) if step.present?
    when TriageFlows::Definition::Route
      TriageFlows::ActionExecutor.new(session).call(transition)
    end
  end

  # A "back to the main menu" option is a legitimate thing to build and both
  # validators accept it, so the engine is what has to end the ride: without a
  # budget a customer can bounce between two questions forever, each hop
  # billing another WhatsApp send and growing the session's jsonb.
  def hop_limit(session)
    session.trace!(:hop_limit, step_id: session.current_step_id, hops: session.path.length)
    TriageFlows::ActionExecutor.new(session).call(definition.no_match.action, status: :fallback)
  end

  # The step this session was parked on was edited away. Staying silent leaves
  # the customer waiting for the timeout job, so the no-match landing is applied
  # now; its own trace event is what makes the edit visible in shadow analysis.
  def step_deleted(session, source)
    session.trace!(:step_deleted, step_id: session.current_step_id, source: source)
    TriageFlows::ActionExecutor.new(session).call(definition.no_match.action, status: :fallback)
  end

  def no_match(session, step, trigger)
    rule = definition.no_match
    session.attempts += 1
    return TriageFlows::ActionExecutor.new(session).call(rule.action, status: :fallback) if session.attempts >= rule.max_attempts

    send_prompt(session, step, trigger, prefix: rule.message)
  end

  def send_prompt(session, step, trigger, prefix: nil)
    prompt_id = deliver_prompt(session, step, trigger, prefix)
    session.current_step_id = step.id
    session.last_prompt_message_id = prompt_id
    session.prompted_at = Time.current
    session.timeout_token = "#{flow.id}:#{flow.version}:#{prompt_id}"
    session.save!
    schedule_timeout(session)
  end

  # Shadow mode sends nothing. It pins the prompt to the triggering message so
  # the ordering guard keeps working and records what a live run would have
  # said.
  def deliver_prompt(session, step, trigger, prefix)
    unless shadow?(session)
      session.trace!(:prompt, step_id: step.id, prefix: prefix)
      return TriageFlows::PromptSender.new(session).call(step, prefix: prefix).id
    end

    session.trace!(:prompt, step_id: step.id, prefix: prefix, shadow: true,
                            prompt: step.prompt, options: step.options.map(&:title))
    Rails.logger.info("[triage][shadow] session=#{session.id} conversation=#{conversation.id} would prompt step=#{step.id}")
    trigger.id
  end

  def schedule_timeout(session)
    timeout = definition.timeout
    return if timeout.blank? || shadow?(session)

    TriageFlows::TimeoutJob.set(wait: timeout.minutes.minutes).perform_later(session.id, session.timeout_token)
  end
end
