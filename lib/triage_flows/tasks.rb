# Query bodies behind lib/tasks/triage_flows.rake, kept out of the rake file so
# they can be tested and so an operator can call them straight from a console.
module TriageFlows::Tasks
  module_function

  def active_sessions(account, inbox_id = nil)
    sessions = TriageSession.active.where(account_id: account.id)
    return sessions if inbox_id.blank?

    sessions.joins(:conversation).where(conversations: { inbox_id: inbox_id })
  end

  # Everything worth knowing at 23:00 on a cutover night, as plain data so the
  # rake task can print it and a spec can assert on it.
  def status(account)
    {
      flows: account.triage_flows.includes(:inbox).map { |flow| flow_status(flow) },
      sessions_last_24h: recent_counts(account),
      active_over_an_hour: active_sessions(account).where(prompted_at: ...1.hour.ago).count,
      pending_without_session: orphaned_conversations(account).count,
      failed_prompts_last_hour: failed_prompts(account).count
    }
  end

  # One screen of plain text for the rake task and for a console at 23:00.
  def status_report(account)
    report = status(account)
    lines = report[:flows].map do |flow|
      "flow ##{flow[:id]} inbox #{flow[:inbox_id]} (#{flow[:inbox]}) v#{flow[:version]} " \
        "mode=#{flow[:mode]} enabled=#{flow[:enabled]} active_sessions=#{flow[:active_sessions]}"
    end
    lines + ["sessions last 24h: #{report[:sessions_last_24h]}",
             "active longer than an hour: #{report[:active_over_an_hour]}",
             "pending and unassigned with no live session: #{report[:pending_without_session]}",
             "failed outbound template messages last hour: #{report[:failed_prompts_last_hour]}"]
  end

  def flow_status(flow)
    { id: flow.id, inbox_id: flow.inbox_id, inbox: flow.inbox.name, version: flow.version,
      mode: flow.mode, enabled: flow.enabled, active_sessions: flow.triage_sessions.active.count }
  end

  def recent_counts(account)
    TriageSession.where(account_id: account.id, created_at: 24.hours.ago..).group(:status).count
  end

  # The failure this whole design exists to prevent: a customer parked in a
  # queue nobody watches, with nothing scheduled to release them.
  def orphaned_conversations(account)
    account.conversations
           .where(status: :pending, assignee_id: nil)
           .where.not(id: TriageSession.active.select(:conversation_id))
  end

  def failed_prompts(account)
    Message.where(account_id: account.id, status: :failed, message_type: :template, created_at: 1.hour.ago..)
  end
end
