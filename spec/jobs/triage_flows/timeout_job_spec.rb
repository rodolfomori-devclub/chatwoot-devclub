require 'rails_helper'

RSpec.describe TriageFlows::TimeoutJob do
  let(:account) { create(:account) }
  let(:tech_team) { create(:team, account: account) }
  let(:general_team) { create(:team, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:triage_flow) do
    create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :live,
                         tech_team: tech_team, general_team: general_team)
  end
  let(:session) do
    create(:triage_session, account: account, triage_flow: triage_flow, conversation: conversation,
                            current_step_id: 'root', timeout_token: 'token-1', prompted_at: 31.minutes.ago)
  end

  before { account.enable_features!('triage_flows') }

  # Releasing a customer parked in `pending` is customer-facing latency: on
  # `low` a busy hour would hold them there until the backlog drained.
  it 'enqueues on the medium queue' do
    expect { described_class.perform_later(session.id, 'token-1') }
      .to have_enqueued_job(described_class).on_queue('medium')
  end

  context 'when the prompt has expired' do
    it 'applies the timeout route and marks the session timed out' do
      described_class.perform_now(session.id, 'token-1')

      expect(session.reload).to be_timed_out
      expect(session.finished_at).to be_present
      expect(conversation.reload.team_id).to eq(general_team.id)
      expect(conversation.status).to eq('open')
    end

    it 'clears the token so a retry cannot fire twice' do
      described_class.perform_now(session.id, 'token-1')

      expect(session.reload.timeout_token).to be_nil
    end
  end

  context 'when the token is stale' do
    it 'does nothing' do
      allow(TriageFlows::ActionExecutor).to receive(:new)

      described_class.perform_now(session.id, 'token-0')

      expect(TriageFlows::ActionExecutor).not_to have_received(:new)
      expect(session.reload).to be_active
      expect(conversation.reload.status).to eq('pending')
    end
  end

  context 'when the session is already terminal' do
    it 'does nothing' do
      allow(TriageFlows::ActionExecutor).to receive(:new)
      session.update!(status: :completed)

      described_class.perform_now(session.id, 'token-1')

      expect(TriageFlows::ActionExecutor).not_to have_received(:new)
      expect(session.reload).to be_completed
      expect(conversation.reload.status).to eq('pending')
    end
  end

  context 'when the session has been deleted' do
    it 'does nothing' do
      expect { described_class.perform_now(session.id + 1, 'token-1') }.not_to raise_error
    end
  end

  context 'when the account feature has been turned off' do
    it 'abandons the session and reopens the pending conversation' do
      account.disable_features!('triage_flows')

      described_class.perform_now(session.id, 'token-1')

      expect(session.reload).to be_abandoned
      expect(session.finished_at).to be_present
      expect(conversation.reload.status).to eq('open')
      expect(conversation.team_id).to be_nil
    end
  end

  context 'when the flow has been disabled' do
    it 'abandons the session and reopens the pending conversation' do
      triage_flow.update!(enabled: false)

      described_class.perform_now(session.id, 'token-1')

      expect(session.reload).to be_abandoned
      expect(conversation.reload.status).to eq('open')
    end

    it 'leaves an already open conversation alone' do
      conversation.update!(status: :open)
      triage_flow.update!(enabled: false)

      described_class.perform_now(session.id, 'token-1')

      expect(session.reload).to be_abandoned
      expect(conversation.reload.status).to eq('open')
    end
  end

  context 'when the flow has no timeout configured' do
    # A live flow cannot be saved without a timeout, so the only way here is a
    # live session whose flow was switched to shadow and stripped afterwards.
    before do
      session
      triage_flow.update!(mode: :shadow)
      triage_flow.update!(definition: triage_flow.definition.except('timeout'))
    end

    it 'reopens the conversation rather than stranding the customer' do
      described_class.perform_now(session.id, 'token-1')

      expect(session.reload).to be_timed_out
      expect(conversation.reload.status).to eq('open')
    end

    it 'leaves the conversation alone when the session itself is a shadow run' do
      session.update!(mode: 'shadow')

      described_class.perform_now(session.id, 'token-1')

      expect(session.reload).to be_timed_out
      expect(conversation.reload.status).to eq('pending')
    end
  end
end
