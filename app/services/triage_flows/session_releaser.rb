# Ends a triage session and gives the conversation back to the team.
#
# Every lever that stops a flow mid-menu lands here — an agent replying, the
# flow being switched off, the flow being deleted, the cancel_active rake task
# — because they all owe the customer the same thing. Runner#hand_over_to_flow
# parks the conversation in `pending` with no assignee, a folder agents do not
# watch, so a session that ends without reopening it strands the customer with
# nothing scheduled to rescue them.
class TriageFlows::SessionReleaser
  # Releases every active session in `scope`, one row lock at a time so a long
  # sweep never holds the whole set. Returns the ids it actually released.
  def self.release_all(scope, reason:)
    scope.includes(:conversation, :triage_flow).filter_map do |session|
      previous = Current.executed_by
      # Stamped as the flow so TriageFlowListener does not re-enter on the
      # status change we are about to make.
      Current.executed_by = session.triage_flow
      session.with_lock { new(session).call(reason) ? session.id : nil }
    ensure
      Current.executed_by = previous
    end
  end

  def initialize(session)
    @session = session
  end

  # Returns true when this call is the one that ended the session.
  def call(reason, **payload)
    return false unless session.active?

    session.trace!(reason, **payload)
    session.update!(status: :abandoned, finished_at: Time.current, timeout_token: nil)
    reopen
    true
  end

  private

  attr_reader :session

  # A shadow session never parked the conversation in pending, so there is
  # nothing to give back; writing here would break the one promise shadow mode
  # makes, that it changes nothing.
  # The conversation can already be gone — a contact or an account being torn
  # down deletes conversations without touching triage_sessions — and there is
  # then nobody left to hand back.
  def reopen
    return if session.mode == 'shadow'

    session.conversation&.open! if session.conversation&.pending?
  end
end
