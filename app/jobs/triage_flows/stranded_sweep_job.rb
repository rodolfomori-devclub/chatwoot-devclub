# Belt and braces for a lost timeout.
#
# TriageFlows::TimeoutJob is enqueued with a delay measured in minutes or
# hours; a Redis flush, a failed enqueue or a worker that dies mid-retry drops
# it, and the customer is left parked in `pending` with no agent assigned and
# nobody looking. This sweep re-drives TimeoutJob for any session that is still
# active long after its prompt should have expired.
#
# Cheap and idempotent by construction: the query rides
# index_triage_sessions_on_status_and_prompted_at, and TimeoutJob is a no-op
# unless the session is still active with a matching token. Safe to run every
# five minutes.
class TriageFlows::StrandedSweepJob < ApplicationJob
  queue_as :low

  # Floor for how long a session may sit unanswered before we intervene, so a
  # flow with a two-minute timeout does not get swept on the heels of its own
  # scheduled job.
  MINIMUM_GRACE = 60.minutes
  BATCH_SIZE = 500

  def perform
    stale_sessions.each { |session| sweep(session) }
  end

  private

  def stale_sessions
    TriageSession.active
                 .where(prompted_at: ...MINIMUM_GRACE.ago)
                 .order(:prompted_at)
                 .limit(BATCH_SIZE)
                 .includes(:triage_flow)
  end

  # One bad row must not take the safety net down for every account on the
  # installation: the sweep is unscoped and runs every five minutes, so it
  # reports and moves on rather than raising into Sidekiq.
  def sweep(session)
    return unless stranded?(session)

    TriageFlows::TimeoutJob.perform_later(session.id, session.timeout_token)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: session.account).capture_exception
  end

  # Twice the flow's own timeout, so a flow configured to wait longer than the
  # grace floor always gets its scheduled job in first.
  #
  # A session whose flow is gone is skipped rather than re-driven every five
  # minutes: nothing can route it any more, and `belongs_to :triage_flow` means
  # it cannot even be saved into a terminal state. TriageFlow#release_active_sessions
  # is what stops one being created; rake triage_flows:status is what finds one
  # that was made by hand.
  def stranded?(session)
    return false if session.triage_flow.blank?

    configured = session.triage_flow.parsed.timeout&.minutes.to_i.minutes
    session.prompted_at <= [configured * 2, MINIMUM_GRACE].max.ago
  end
end
