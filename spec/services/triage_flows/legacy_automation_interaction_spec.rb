require 'rails_helper'

# The engine does not run in a vacuum: DevClub account 2 carries seven legacy
# automation rules from the text-menu era. AutomationRuleListener only skips
# events whose performed_by is an AutomationRule (automation_rule_listener.rb),
# so every conversation write the engine makes re-enters those rules.
#
# These examples pin the two interactions that would put two menus in front of
# the same customer, so the rollout runbook's "disable rules #1 and #70" step
# can never be quietly dropped.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Triage flow vs legacy automation rules' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:flow) { TriageFlows::SeedService.new(account: account, inbox: inbox).perform }
  let(:contact) { create(:contact, account: account) }
  let(:conversation) do
    create(:conversation, account: account, inbox: inbox, contact: contact,
                          contact_inbox: create(:contact_inbox, contact: contact, inbox: inbox))
  end

  # Faithful replica of production rule #70.
  def legacy_recurring_contact_rule
    create(:automation_rule, account: account, event_name: 'conversation_updated', active: true,
                             name: 'Envie a condição para contatos existentes',
                             conditions: [
                               { 'values' => ['pending'], 'attribute_key' => 'status', 'query_operator' => 'and',
                                 'filter_operator' => 'equal_to', 'custom_attribute_type' => '' },
                               { 'values' => [], 'attribute_key' => 'labels', 'query_operator' => 'and',
                                 'filter_operator' => 'is_not_present', 'custom_attribute_type' => '' },
                               { 'values' => [], 'attribute_key' => 'team_id', 'query_operator' => 'and',
                                 'filter_operator' => 'is_not_present', 'custom_attribute_type' => '' },
                               { 'values' => [], 'attribute_key' => 'assignee_id',
                                 'filter_operator' => 'is_not_present', 'custom_attribute_type' => '' }
                             ],
                             actions: [
                               { 'action_name' => 'add_label', 'action_params' => ['novo_atendimento'] },
                               { 'action_name' => 'send_message', 'action_params' => ['MENU DE TEXTO ANTIGO'] }
                             ])
  end

  before do
    # SeedService resolves the tree's routes against these by name.
    ['suporte técnico', 'suporte geral', 'suporte financeiro', 'suporte renovação'].each do |name|
      create(:team, account: account, name: name)
    end
    account.enable_features!('triage_flows')
    flow.update!(enabled: true, mode: :live)
  end

  # Count by provenance, not by content type: the widget channel emits its own
  # onboarding templates, which have nothing to do with this interaction.
  # Message#content_attributes is a `store` with a JSON coder, so the marker is
  # not reachable with a jsonb operator — filter in Ruby.
  def triage_menus
    conversation.reload.messages.select { |m| m.content_attributes['triage'].present? }
  end

  def legacy_menus
    conversation.reload.messages.where(content: 'MENU DE TEXTO ANTIGO')
  end

  def deliver_incoming(content)
    message = nil
    perform_enqueued_jobs(only: EventDispatcherJob) do
      message = conversation.messages.create!(account: account, inbox: inbox, message_type: :incoming, content: content)
    end
    3.times { perform_enqueued_jobs(only: EventDispatcherJob) }
    message
  end

  context 'when the legacy conversation_updated rule is still active' do
    before { legacy_recurring_contact_rule }

    it 'sends the customer two menus, because the engine start write re-enters the rule' do
      deliver_incoming('Oi, preciso de ajuda')

      expect(triage_menus.count).to eq(1)
      expect(legacy_menus.count).to eq(1)
    end
  end

  context 'when the legacy rule is disabled, as the runbook requires' do
    before { legacy_recurring_contact_rule.update!(active: false) }

    it 'sends exactly one menu' do
      deliver_incoming('Oi, preciso de ajuda')

      expect(triage_menus.count).to eq(1)
      expect(triage_menus.first.content_type).to eq('input_select')
      expect(legacy_menus).to be_empty
    end
  end

  context 'when the flow is in shadow mode' do
    before do
      flow.update!(mode: :shadow)
      legacy_recurring_contact_rule
    end

    # Shadow writes nothing to the conversation, so it cannot wake the legacy
    # rules — which is why observing in shadow on production is safe.
    it 'does not trigger the legacy rule' do
      deliver_incoming('Oi, preciso de ajuda')

      expect(triage_menus).to be_empty
      expect(legacy_menus).to be_empty
    end
  end
end
# rubocop:enable RSpec/DescribeClass
