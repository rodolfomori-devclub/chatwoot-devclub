# == Schema Information
#
# Table name: triage_sessions
#
#  id                     :bigint           not null, primary key
#  attempts               :integer          default(0), not null
#  finished_at            :datetime
#  flow_version           :integer          not null
#  mode                   :string           not null
#  outcome                :jsonb            not null
#  path                   :jsonb            not null
#  prompted_at            :datetime
#  status                 :integer          default("active"), not null
#  timeout_token          :string
#  trace                  :jsonb            not null
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  account_id             :bigint           not null
#  conversation_id        :bigint           not null
#  current_step_id        :string
#  last_input_message_id  :bigint
#  last_prompt_message_id :bigint
#  triage_flow_id         :bigint           not null
#
# Indexes
#
#  index_triage_sessions_on_account_id              (account_id)
#  index_triage_sessions_on_conversation_id         (conversation_id) UNIQUE
#  index_triage_sessions_on_status_and_prompted_at  (status,prompted_at)
#  index_triage_sessions_on_triage_flow_id          (triage_flow_id)
#
class TriageSession < ApplicationRecord
  TRACE_LIMIT = 20

  belongs_to :account
  belongs_to :triage_flow
  belongs_to :conversation

  enum status: { active: 0, completed: 1, fallback: 2, timed_out: 3, abandoned: 4 }

  scope :terminal, -> { where.not(status: :active) }

  def terminal?
    !active?
  end

  # Trace is the shadow-mode audit trail and the production debugging aid.
  # Bounded so the jsonb column never grows without limit.
  def trace!(event, **payload)
    self.trace = (trace + [payload.merge(event: event.to_s).stringify_keys]).last(TRACE_LIMIT)
  end

  def record_step(step_id, input: nil, option_id: nil)
    self.path = path + [{ 'step_id' => step_id, 'input' => input, 'option_id' => option_id }]
  end
end

TriageSession.include_mod_with('Concerns::TriageSession')
