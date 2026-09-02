require 'rails_helper'

# The dashboard runs a mirror of this validator so the builder can refuse a
# definition before it is posted. Both sides read the same fixture: the vitest
# suite in
# app/javascript/dashboard/routes/dashboard/settings/triageFlows/helpers/specs/parity.spec.js
# asserts the JS mirror produces exactly the message list recorded here, and
# this spec asserts the Ruby validator does too. A rule that changes on one
# side fails on the other.
RSpec.describe TriageFlows::DefinitionValidator do
  let(:account) { create(:account) }
  let(:widget_inbox) { create(:inbox, account: account) }
  let(:whatsapp_inbox) do
    create(:inbox, account: account,
                   channel: create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false))
  end

  let(:cases) { JSON.parse(Rails.root.join('spec/fixtures/triage_flows/validator_parity.json').read) }

  def inbox_for(channel_type)
    channel_type == 'Channel::Whatsapp' ? whatsapp_inbox : widget_inbox
  end

  def errors_for(kase)
    flow = TriageFlow.new(account: account, inbox: inbox_for(kase['channel_type']),
                          name: kase['name'], mode: kase['mode'], definition: kase['definition'])
    flow.valid?
    flow.errors[:definition]
  end

  it 'covers both channels, both modes and every rule' do
    expect(cases.length).to be >= 10
    expect(cases.map { |c| c['channel_type'] }.uniq).to contain_exactly('Channel::Whatsapp', 'Channel::WebWidget')
    expect(cases.map { |c| c['mode'] }.uniq).to contain_exactly('shadow', 'live')
  end

  it 'produces exactly the recorded messages for every case' do
    mismatches = cases.filter_map do |kase|
      actual = errors_for(kase).sort
      expected = kase['expected_errors'].sort
      "#{kase['name']}: expected #{expected.inspect}, got #{actual.inspect}" if actual != expected
    end

    expect(mismatches).to eq([])
  end

  it 'reports exactly the recorded unreachable steps for every case' do
    mismatches = cases.filter_map do |kase|
      definition = TriageFlows::Definition.new(kase['definition'])
      actual = definition.unreachable_step_ids.sort
      expected = kase['expected_unreachable'].sort
      "#{kase['name']}: expected #{expected.inspect}, got #{actual.inspect}" if actual != expected
    end

    expect(mismatches).to eq([])
  end
end
