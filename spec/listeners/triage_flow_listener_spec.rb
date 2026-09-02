require 'rails_helper'

describe TriageFlowListener do
  let(:listener) { described_class.instance }
  let!(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox, enabled: true) }
  let(:runner) { instance_double(TriageFlows::Runner, incoming: nil, agent_took_over: nil, widget_reply: nil) }

  before do
    account.enable_features!('triage_flows')
    allow(TriageFlows::Runner).to receive(:new).and_return(runner)
  end

  def created_event(message, performed_by: nil)
    Events::Base.new('message_created', Time.zone.now, { message: message, performed_by: performed_by })
  end

  def updated_event(message, previous_changes, performed_by: nil)
    Events::Base.new('message_updated', Time.zone.now,
                     { message: message, performed_by: performed_by, previous_changes: previous_changes })
  end

  def build_message(**attrs)
    create(:message, { account: account, inbox: inbox, conversation: conversation }.merge(attrs))
  end

  describe '#message_created' do
    context 'with an incoming message' do
      let(:message) { build_message(message_type: :incoming) }

      it 'drives the runner with the inbox flow' do
        listener.message_created(created_event(message))

        expect(TriageFlows::Runner).to have_received(:new).with(triage_flow, conversation)
        expect(runner).to have_received(:incoming).with(message)
      end

      it 'ignores a message the flow itself performed' do
        listener.message_created(created_event(message, performed_by: triage_flow))

        expect(TriageFlows::Runner).not_to have_received(:new)
      end

      it 'ignores the message when the account feature is disabled' do
        account.disable_features!('triage_flows')

        listener.message_created(created_event(message))

        expect(TriageFlows::Runner).not_to have_received(:new)
      end

      it 'ignores the message when the flow is disabled' do
        triage_flow.update!(enabled: false)

        listener.message_created(created_event(message))

        expect(TriageFlows::Runner).not_to have_received(:new)
      end

      it 'ignores the message when the inbox has no flow' do
        other_conversation = create(:conversation, account: account)

        listener.message_created(created_event(build_message(conversation: other_conversation,
                                                             inbox: other_conversation.inbox,
                                                             message_type: :incoming)))

        expect(TriageFlows::Runner).not_to have_received(:new)
      end
    end

    context 'with a private note' do
      it 'ignores the message' do
        agent = create(:user, account: account, role: :agent)

        listener.message_created(created_event(build_message(message_type: :outgoing, private: true, sender: agent)))

        expect(TriageFlows::Runner).not_to have_received(:new)
      end
    end

    context 'with an activity message' do
      it 'ignores the message' do
        listener.message_created(created_event(build_message(message_type: :activity, content: 'Conversation was marked resolved')))

        expect(TriageFlows::Runner).not_to have_received(:new)
      end
    end

    context 'with an outgoing message' do
      it 'hands over when an agent replies' do
        agent = create(:user, account: account, role: :agent)
        message = build_message(message_type: :outgoing, sender: agent)

        listener.message_created(created_event(message))

        expect(runner).to have_received(:agent_took_over).with(message)
      end

      it 'does nothing when an agent bot replies' do
        message = build_message(message_type: :outgoing, sender: create(:agent_bot))

        listener.message_created(created_event(message))

        expect(runner).not_to have_received(:incoming)
        expect(runner).not_to have_received(:agent_took_over)
      end
    end
  end

  describe '#message_updated' do
    let(:items) { [{ 'title' => 'Financeiro', 'value' => 'financeiro' }] }
    let(:marker) { { 'flow_id' => triage_flow.id, 'session_id' => 1, 'step_id' => 'root', 'version' => triage_flow.version } }
    let(:before_submission) { { 'items' => items, 'triage' => marker } }
    let(:after_submission) { before_submission.merge('submitted_values' => [{ 'title' => 'Financeiro', 'value' => 'financeiro' }]) }
    let(:menu_message) do
      build_message(message_type: :template, content_type: 'input_select', content: 'Como podemos ajudar?',
                    content_attributes: before_submission)
    end

    def submission_changes(before, after)
      { 'content_attributes' => [before, after] }
    end

    it 'drives the runner with the submitted option id' do
      listener.message_updated(updated_event(menu_message, submission_changes(before_submission, after_submission)))

      expect(TriageFlows::Runner).to have_received(:new).with(triage_flow, conversation)
      expect(runner).to have_received(:widget_reply).with(menu_message, 'financeiro')
    end

    it 'ignores a later update once a value is already submitted' do
      second = after_submission.merge('submitted_values' => [{ 'title' => 'Outro', 'value' => 'outro' }])

      listener.message_updated(updated_event(menu_message, submission_changes(after_submission, second)))

      expect(TriageFlows::Runner).not_to have_received(:new)
    end

    it 'ignores an update that does not touch content_attributes' do
      listener.message_updated(updated_event(menu_message, { 'content' => %w[a b] }))

      expect(TriageFlows::Runner).not_to have_received(:new)
    end

    it 'ignores a message that is not an input_select' do
      text_message = build_message(content_attributes: before_submission)

      listener.message_updated(updated_event(text_message, submission_changes(before_submission, after_submission)))

      expect(TriageFlows::Runner).not_to have_received(:new)
    end

    it 'ignores an input_select that the flow did not send' do
      untagged_before = { 'items' => items }
      untagged_after = untagged_before.merge('submitted_values' => after_submission['submitted_values'])
      foreign = build_message(message_type: :template, content_type: 'input_select', content: 'Rate us',
                              content_attributes: untagged_before)

      listener.message_updated(updated_event(foreign, submission_changes(untagged_before, untagged_after)))

      expect(TriageFlows::Runner).not_to have_received(:new)
    end

    it 'ignores an update the flow itself performed' do
      listener.message_updated(updated_event(menu_message, submission_changes(before_submission, after_submission),
                                             performed_by: triage_flow))

      expect(TriageFlows::Runner).not_to have_received(:new)
    end
  end
end
