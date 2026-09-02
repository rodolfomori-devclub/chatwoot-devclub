require 'rails_helper'
require 'rake'

Rake.application.rake_require('tasks/triage_flows') unless Rake::Task.task_defined?('triage_flows:cancel_active')
Rake::Task.define_task(:environment)

# The kill switch. It gets pasted into a production console on a bad night, so
# it is the one piece of this feature that must not be the first execution of
# untested code.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'triage_flows rake tasks' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:other_inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: :pending, assignee: nil) }
  let(:flow) { create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :live) }
  let!(:session) do
    create(:triage_session, account: account, triage_flow: flow, conversation: conversation, mode: 'live',
                            timeout_token: 'token-1')
  end

  before { Rake::Task['triage_flows:cancel_active'].reenable }

  def cancel(*)
    Rake::Task['triage_flows:cancel_active'].invoke(*)
  end

  describe 'cancel_active' do
    it 'abandons the session and gives the conversation back to the team' do
      expect { cancel(account.id) }.to output(/Abandoned 1 session/).to_stdout

      expect(session.reload).to be_abandoned
      expect(session.timeout_token).to be_nil
      expect(conversation.reload.status).to eq('open')
    end

    it 'prints what it would do and changes nothing in dry run' do
      with_modified_env DRY_RUN: '1' do
        expect { cancel(account.id) }.to output(/DRY RUN — would abandon 1 session/).to_stdout
      end

      expect(session.reload).to be_active
      expect(conversation.reload.status).to eq('pending')
    end

    it 'can be limited to one inbox so the other channel keeps running' do
      spared_conversation = create(:conversation, account: account, inbox: other_inbox, status: :pending, assignee: nil)
      spared_flow = create(:triage_flow, account: account, inbox: other_inbox, enabled: true, mode: :live)
      spared = create(:triage_session, account: account, triage_flow: spared_flow, conversation: spared_conversation,
                                       mode: 'live')

      cancel(account.id, inbox.id)

      expect(session.reload).to be_abandoned
      expect(spared.reload).to be_active
    end

    it 'leaves sessions that already finished alone' do
      session.update!(status: :completed)

      expect { cancel(account.id) }.to output(/Abandoned 0 session/).to_stdout
    end
  end

  # The three numbers you want in the first hour of a cutover, so nobody has to
  # invent the queries under pressure.
  describe 'status' do
    it 'reports the flow, the live sessions and the customers nothing is holding' do
      stranded = create(:conversation, account: account, inbox: other_inbox, status: :pending, assignee: nil)
      report = TriageFlows::Tasks.status_report(account)

      expect(report.first).to include("flow ##{flow.id}", 'mode=live', 'enabled=true', 'active_sessions=1')
      expect(report).to include(a_string_including('pending and unassigned with no live session: 1'))
      expect(TriageFlows::Tasks.orphaned_conversations(account)).to contain_exactly(stranded)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
