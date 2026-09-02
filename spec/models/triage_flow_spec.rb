require 'rails_helper'

RSpec.describe TriageFlow do
  let(:account) { create(:account) }
  let!(:team) { create(:team, account: account) }

  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:inbox) }
  end

  describe 'validations' do
    it 'is valid with the default definition' do
      expect(build(:triage_flow, account: account)).to be_valid
    end

    it 'requires a name' do
      flow = build(:triage_flow, account: account, name: nil)
      expect(flow).not_to be_valid
      expect(flow.errors[:name]).to be_present
    end

    it 'allows only one flow per inbox' do
      existing = create(:triage_flow, account: account)
      duplicate = build(:triage_flow, account: account, inbox: existing.inbox)
      expect(duplicate).not_to be_valid
    end

    it 'rejects an inbox from another account' do
      flow = build(:triage_flow, account: account, inbox: create(:inbox, account: create(:account)))
      expect(flow).not_to be_valid
    end
  end

  describe 'definition validation' do
    def flow_with(definition)
      build(:triage_flow, account: account, definition: definition)
    end

    let(:route) { { 'type' => 'route', 'team_id' => team.id, 'labels' => [], 'status' => 'open' } }

    def one_step(options)
      { 'entry_step_id' => 'root', 'steps' => [{ 'id' => 'root', 'prompt' => 'p', 'options' => options }],
        'no_match' => { 'message' => 'x', 'max_attempts' => 3, 'then' => route },
        'timeout' => { 'minutes' => 30, 'then' => route } }
    end

    it 'rejects an empty definition' do
      expect(flow_with({})).not_to be_valid
    end

    it 'rejects an unknown entry step' do
      d = one_step([{ 'id' => 'a', 'title' => 'A', 'next' => route }]).merge('entry_step_id' => 'nope')
      expect(flow_with(d)).not_to be_valid
    end

    it 'rejects an option pointing at a nonexistent step' do
      d = one_step([{ 'id' => 'a', 'title' => 'A', 'next' => { 'type' => 'step', 'step_id' => 'ghost' } }])
      expect(flow_with(d)).not_to be_valid
    end

    it 'rejects a step pointing at itself' do
      d = one_step([{ 'id' => 'a', 'title' => 'A', 'next' => { 'type' => 'step', 'step_id' => 'root' } }])
      expect(flow_with(d)).not_to be_valid
    end

    it 'rejects two options with the same normalised title' do
      d = one_step([{ 'id' => 'a', 'title' => 'Renovação', 'next' => route },
                    { 'id' => 'b', 'title' => 'renovacao', 'next' => route }])
      expect(flow_with(d)).not_to be_valid
    end

    it 'rejects a team from another account' do
      other = create(:team, account: create(:account))
      d = one_step([{ 'id' => 'a', 'title' => 'A', 'next' => route.merge('team_id' => other.id) }])
      expect(flow_with(d)).not_to be_valid
    end

    it 'rejects max_attempts outside 1..5' do
      d = one_step([{ 'id' => 'a', 'title' => 'A', 'next' => route }])
      d['no_match']['max_attempts'] = 9
      expect(flow_with(d)).not_to be_valid
    end

    it 'requires a timeout when the flow is live' do
      d = one_step([{ 'id' => 'a', 'title' => 'A', 'next' => route }]).except('timeout')
      expect(build(:triage_flow, account: account, mode: :live, definition: d)).not_to be_valid
    end

    it 'allows a shadow flow without a timeout' do
      d = one_step([{ 'id' => 'a', 'title' => 'A', 'next' => route }]).except('timeout')
      expect(build(:triage_flow, account: account, mode: :shadow, definition: d)).to be_valid
    end
  end

  describe 'WhatsApp channel limits' do
    # Chatwoot does not truncate: an over-long title makes Meta reject the whole
    # message and the customer silently receives nothing.
    let(:inbox) do
      create(:inbox, account: account, channel: create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false))
    end
    let(:route) { { 'type' => 'route', 'team_id' => team.id, 'labels' => [], 'status' => 'open' } }

    def wa_flow(titles)
      options = titles.each_with_index.map { |t, i| { 'id' => "o#{i}", 'title' => t, 'next' => route } }
      build(:triage_flow, account: account, inbox: inbox, definition: {
              'entry_step_id' => 'root', 'steps' => [{ 'id' => 'root', 'prompt' => 'p', 'options' => options }],
              'no_match' => { 'message' => 'x', 'max_attempts' => 3, 'then' => route },
              'timeout' => { 'minutes' => 30, 'then' => route }
            })
    end

    it 'accepts 3 button titles within 20 chars' do
      expect(wa_flow(['Dúvidas Técnicas', 'Dúvidas Gerais', 'Financeiro'])).to be_valid
    end

    it 'rejects a button title over 20 chars' do
      expect(wa_flow(['A' * 21, 'B', 'C'])).not_to be_valid
    end

    it 'allows up to 24 chars once it becomes a list' do
      expect(wa_flow(['A' * 21, 'B', 'C', 'D'])).to be_valid
    end

    it 'rejects more than 10 options' do
      expect(wa_flow(Array.new(11) { |i| "Op #{i}" })).not_to be_valid
    end
  end

  describe 'versioning' do
    it 'bumps version when the definition changes' do
      flow = create(:triage_flow, account: account)
      expect { flow.update!(definition: flow.definition.merge('entry_step_id' => 'root')) }.not_to(change { flow.reload.version })

      d = flow.definition.deep_dup
      d['steps'][0]['prompt'] = 'novo texto'
      expect { flow.update!(definition: d) }.to change { flow.reload.version }.by(1)
    end

    it 'does not bump version for unrelated changes' do
      flow = create(:triage_flow, account: account)
      expect { flow.update!(name: 'Outro nome') }.not_to(change { flow.reload.version })
    end
  end

  # Both levers used to leave the customer behind: Runner#hand_over_to_flow
  # parks the conversation in `pending` with no assignee, and once the session
  # is gone (or answering nothing) nothing is scheduled to bring it back.
  describe 'stopping a flow with customers mid-menu' do
    let(:inbox) { create(:inbox, account: account) }
    let(:flow) { create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :live) }
    let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending, assignee: nil) }
    let!(:session) do
      create(:triage_session, account: account, triage_flow: flow, conversation: conversation, mode: 'live')
    end

    it 'hands the conversation back when the flow is switched off' do
      flow.update!(enabled: false)

      expect(session.reload).to be_abandoned
      expect(conversation.reload.status).to eq('open')
    end

    it 'hands the conversation back before the flow is destroyed' do
      flow.destroy!

      expect(conversation.reload.status).to eq('open')
      # destroy_async may already have taken the row; what matters is that the
      # customer was handed back before it went.
      expect(TriageSession.where(id: session.id, status: :active)).to be_empty
    end

    it 'leaves the conversation of a shadow session exactly where it was' do
      session.update!(mode: 'shadow')
      conversation.update!(status: :open)

      flow.update!(enabled: false)

      expect(session.reload).to be_abandoned
      expect(conversation.reload.status).to eq('open')
    end

    it 'does nothing when the flow is switched on' do
      flow.update!(enabled: false)
      session.update!(status: :active)

      expect { flow.update!(enabled: true) }.not_to(change { session.reload.status })
    end
  end

  describe '#warnings' do
    it 'reports unreachable steps without blocking save' do
      flow = create(:triage_flow, account: account)
      d = flow.definition.deep_dup
      d['steps'] << { 'id' => 'orfao', 'prompt' => 'p',
                      'options' => [{ 'id' => 'x', 'title' => 'X',
                                      'next' => { 'type' => 'route', 'team_id' => team.id, 'labels' => [], 'status' => 'open' } }] }
      flow.update!(definition: d)
      expect(flow.reload.warnings).to include(hash_including('type' => 'unreachable_step', 'step_id' => 'orfao'))
    end
  end
end
