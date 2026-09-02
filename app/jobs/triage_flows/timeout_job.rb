# Fires when a customer stops answering the menu. Enqueued with a delay by
# TriageFlows::Runner#send_prompt and re-driven by TriageFlows::StrandedSweepJob.
#
# The token is the idempotency key: every prompt stamps a fresh one, so a job
# scheduled against an older prompt (or a Sidekiq retry of a job that already
# ran) finds a mismatch and does nothing.
class TriageFlows::TimeoutJob < ApplicationJob
  # Customer-facing latency, not housekeeping: on the strict-priority queue list
  # `low` only drains once everything above it is empty, so a busy hour would
  # hold every parked customer in `pending` for as long as the backlog lasts.
  queue_as :medium

  def perform(session_id, token)
    session = TriageSession.find_by(id: session_id)
    return if session.blank?

    # Set outside the lock so the flow is still stamped on the writes the
    # transaction dispatches when it commits.
    Current.executed_by = session.triage_flow
    session.with_lock { fire(session, token) }
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: session&.account).capture_exception
  ensure
    Current.executed_by = nil
  end

  private

  def fire(session, token)
    return unless session.active?
    return unless session.timeout_token == token

    inactive?(session) ? release(session) : expire(session)
  end

  # A nil flow is a session whose flow was deleted out from under it: nothing
  # can route it any more, so it counts as inactive and gets released.
  def inactive?(session)
    !session.account.feature_enabled?('triage_flows') || !session.triage_flow&.enabled?
  end

  # The flow was switched off while a customer sat mid-menu. Hand the
  # conversation back to the humans instead of leaving it parked in pending
  # where nobody is looking at it.
  def release(session)
    reopen(session)
    session.trace!('timeout_released', reason: 'flow_inactive')
    finish(session, :abandoned)
  end

  def expire(session)
    action = session.triage_flow.parsed.timeout&.action
    return strand_guard(session) unless action.is_a?(TriageFlows::Definition::Route)

    session.trace!('timeout', step_id: session.current_step_id)
    TriageFlows::ActionExecutor.new(session).call(action, status: :timed_out)
  end

  # A flow saved before the timeout became mandatory, or one whose timeout
  # routes nowhere. Same rule as #release: never leave a customer stranded.
  def strand_guard(session)
    reopen(session)
    session.trace!('timeout', step_id: session.current_step_id, action: nil)
    finish(session, :timed_out)
  end

  # A shadow session never parked the conversation in pending, so there is
  # nothing to release; writing here would break the one promise shadow mode
  # makes, that it changes nothing.
  def reopen(session)
    return if session.mode == 'shadow'

    conversation = session.conversation
    conversation.open! if conversation&.pending?
  end

  def finish(session, status)
    session.status = status
    session.finished_at = Time.current
    session.timeout_token = nil
    session.save!
  end
end
