require 'rails_helper'

RSpec.describe TriageSession do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:flow) { create(:triage_flow, account: account, inbox: inbox) }
  let(:session) { create(:triage_session, account: account, triage_flow: flow, conversation: conversation) }

  describe 'associations' do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:triage_flow) }
    it { is_expected.to belong_to(:conversation) }
  end

  describe '#trace!' do
    it 'records the event alongside its payload' do
      session.trace!(:prompt, step_id: 'root')

      expect(session.trace.last).to eq('event' => 'prompt', 'step_id' => 'root')
    end

    # The trace is the shadow-mode audit trail and lives in a jsonb column on a
    # row a looping customer can revisit many times.
    it 'keeps only the most recent entries' do
      (described_class::TRACE_LIMIT + 5).times { |index| session.trace!(:input, step_id: index.to_s) }

      expect(session.trace.length).to eq(described_class::TRACE_LIMIT)
      expect(session.trace.first['step_id']).to eq('5')
    end
  end

  describe '#record_step' do
    it 'appends the answered step to the path' do
      session.record_step('root', input: 'Financeiro', option_id: 'financeiro')

      expect(session.path).to eq([{ 'step_id' => 'root', 'input' => 'Financeiro', 'option_id' => 'financeiro' }])
    end
  end

  describe 'status' do
    it 'reports every non-active status as terminal' do
      expect(session).not_to be_terminal

      session.update!(status: :fallback)

      expect(session.reload).to be_terminal
      expect(described_class.terminal).to include(session)
    end
  end
end
