require 'rails_helper'

RSpec.describe TriageFlows::StrandedSweepJob do
  let(:account) { create(:account) }
  let(:tech_team) { create(:team, account: account) }
  let(:general_team) { create(:team, account: account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending) }
  let(:triage_flow) do
    create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :live,
                         tech_team: tech_team, general_team: general_team)
  end

  # The flow's own timeout is 30 minutes, so the grace floor of 60 minutes wins.
  def session_prompted(ago, status: :active)
    create(:triage_session, account: account, triage_flow: triage_flow, conversation: conversation,
                            status: status, current_step_id: 'root', timeout_token: 'token-1', prompted_at: ago)
  end

  before { account.enable_features!('triage_flows') }

  # Housekeeping, but above scheduled_jobs: on the strict-priority queue list
  # the safety net must not sit below every other background sweep.
  it 'enqueues on the low queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('low')
  end

  it 're-drives the timeout job with the session current token' do
    session = session_prompted(3.hours.ago)

    expect { described_class.perform_now }
      .to have_enqueued_job(TriageFlows::TimeoutJob).with(session.id, 'token-1')
  end

  it 'leaves a session inside the grace window alone' do
    session_prompted(55.minutes.ago)

    expect { described_class.perform_now }.not_to have_enqueued_job(TriageFlows::TimeoutJob)
  end

  it 'waits out a flow whose own timeout is longer than the grace floor' do
    definition = triage_flow.definition.deep_dup
    definition['timeout']['minutes'] = 720
    triage_flow.update!(definition: definition)
    session_prompted(3.hours.ago)

    expect { described_class.perform_now }.not_to have_enqueued_job(TriageFlows::TimeoutJob)
  end

  it 'ignores terminal sessions' do
    session_prompted(3.hours.ago, status: :completed)

    expect { described_class.perform_now }.not_to have_enqueued_job(TriageFlows::TimeoutJob)
  end

  it 'ignores a session that was never prompted' do
    session_prompted(nil)

    expect { described_class.perform_now }.not_to have_enqueued_job(TriageFlows::TimeoutJob)
  end

  # The sweep is unscoped and runs every five minutes for the whole
  # installation, so one unusable row must not take the safety net down for
  # every other account.
  it 'keeps sweeping past a session whose flow is gone' do
    orphan = session_prompted(4.hours.ago)
    other_inbox = create(:inbox, account: account)
    other_conversation = create(:conversation, account: account, inbox: other_inbox, status: :pending)
    healthy_flow = create(:triage_flow, account: account, inbox: other_inbox, enabled: true, mode: :live)
    healthy = create(:triage_session, account: account, triage_flow: healthy_flow, conversation: other_conversation,
                                      current_step_id: 'root', timeout_token: 'token-2', prompted_at: 3.hours.ago)
    TriageFlow.where(id: orphan.triage_flow_id).delete_all

    expect { described_class.perform_now }
      .to have_enqueued_job(TriageFlows::TimeoutJob).with(healthy.id, 'token-2').exactly(:once)
  end

  it 'leaves the customer with an agent rather than parked in pending' do
    session = session_prompted(3.hours.ago)

    perform_enqueued_jobs { described_class.perform_now }

    expect(session.reload).to be_timed_out
    expect(conversation.reload.status).to eq('open')
  end
end
