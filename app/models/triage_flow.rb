# == Schema Information
#
# Table name: triage_flows
#
#  id         :bigint           not null, primary key
#  definition :jsonb            not null
#  enabled    :boolean          default(FALSE), not null
#  mode       :integer          default("shadow"), not null
#  name       :string(255)      not null
#  version    :integer          default(1), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint           not null
#  inbox_id   :bigint           not null
#
# Indexes
#
#  index_triage_flows_on_account_id  (account_id)
#  index_triage_flows_on_inbox_id    (inbox_id) UNIQUE
#
class TriageFlow < ApplicationRecord
  belongs_to :account
  belongs_to :inbox
  has_many :triage_sessions, dependent: :destroy_async

  enum mode: { shadow: 0, live: 1 }

  validates :name, presence: true
  validates :inbox_id, uniqueness: true
  validate :inbox_belongs_to_account
  validates_with TriageFlows::DefinitionValidator

  before_update :bump_version, if: :definition_changed?
  # Both run before the sessions can become unreachable: destroy_async wipes the
  # rows a moment later, and a disabled flow stops answering the customer at
  # once, so anyone mid-menu has to be handed back now rather than waiting out
  # a timeout nobody is watching.
  before_destroy :release_active_sessions
  after_update_commit :release_active_sessions, if: :switched_off?

  # Parsed view over the raw jsonb. The engine never touches `definition`
  # directly, so a shape change has exactly one place to land.
  #
  # Memoised, but keyed on the raw hash: the validator parses during save and
  # #reload swaps the attribute underneath us, so a plain ||= would keep
  # serving the pre-update definition.
  def parsed
    return @parsed if defined?(@parsed) && @parsed_source == definition

    @parsed_source = definition
    @parsed = TriageFlows::Definition.new(definition)
  end

  def warnings
    parsed.warnings(account)
  end

  # Sessions in flight when the flow is stopped, with their conversations put
  # back in the agents' hands.
  def release_active_sessions
    TriageFlows::SessionReleaser.release_all(triage_sessions.active, reason: :flow_stopped)
  end

  private

  def switched_off?
    saved_change_to_enabled? && !enabled?
  end

  def bump_version
    self.version += 1
  end

  def inbox_belongs_to_account
    return if inbox.blank? || account_id.blank?

    errors.add(:inbox, I18n.t('triage_flow.errors.inbox_account_mismatch')) if inbox.account_id != account_id
  end
end

TriageFlow.include_mod_with('Concerns::TriageFlow')
