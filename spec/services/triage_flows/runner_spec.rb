require 'rails_helper'

RSpec.describe TriageFlows::Runner do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:tech_team) { create(:team, account: account) }
  let(:general_team) { create(:team, account: account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:flow) do
    create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :live,
                         tech_team: tech_team, general_team: general_team)
  end
  let(:runner) { described_class.new(flow, conversation) }

  def incoming(content)
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :incoming, content: content)
  end

  def start_flow
    runner.incoming(incoming('Oi'))
  end

  def triage_session
    TriageSession.find_by(conversation_id: conversation.id)
  end

  def last_prompt
    conversation.messages.reload.last
  end

  describe '#incoming on a fresh conversation' do
    it 'opens a session stamped with the flow version and mode' do
      start_flow

      expect(triage_session).to be_present
      expect(triage_session.current_step_id).to eq('root')
      expect(triage_session.flow_version).to eq(flow.version)
      expect(triage_session.mode).to eq('live')
      expect(triage_session.attempts).to eq(0)
    end

    it 'takes the conversation away from the agent and parks it in pending' do
      expect(conversation.assignee_id).to eq(agent.id)

      start_flow

      expect(conversation.reload.status).to eq('pending')
      expect(conversation.assignee_id).to be_nil
    end

    it 'sends exactly one prompt' do
      message = incoming('Oi')

      expect { runner.incoming(message) }.to change(Message, :count).by(1)
    end

    it 'builds the prompt as a template input_select carrying the triage marker' do
      start_flow
      prompt = last_prompt

      expect(prompt.message_type).to eq('template')
      expect(prompt.content_type).to eq('input_select')
      expect(prompt.content).to eq('Como podemos ajudar?')
      expect(prompt.content_attributes['items'].pluck('value')).to eq(%w[tecnico gerais financeiro])
      expect(prompt.content_attributes['triage']).to include('step_id' => 'root', 'flow_id' => flow.id,
                                                             'session_id' => triage_session.id)
    end

    it 'points the session at the prompt it just sent' do
      start_flow

      expect(triage_session.last_prompt_message_id).to eq(last_prompt.id)
      expect(triage_session.prompted_at).to be_present
    end

    it 'enqueues the timeout job with the prompt token' do
      start_flow

      expect(TriageFlows::TimeoutJob).to have_been_enqueued
        .with(triage_session.id, "#{flow.id}:#{flow.version}:#{last_prompt.id}")
    end

    it 'does not score the message that triggered the start' do
      message = incoming('Oi')

      expect { runner.incoming(message) }.to change(Message, :count).by(1)
      expect(triage_session.attempts).to eq(0)
      expect(triage_session.current_step_id).to eq('root')
      expect(triage_session.path).to be_empty
    end
  end

  describe '#incoming eligibility' do
    it 'does not start when the customer has messaged before' do
      incoming('Oi')
      message = incoming('alguem ai?')

      expect { runner.incoming(message) }.not_to change(Message, :count)
      expect(triage_session).to be_nil
    end

    it 'does not start when an agent has already replied' do
      create(:message, account: account, inbox: inbox, conversation: conversation, message_type: :outgoing, sender: agent)
      message = incoming('Oi')

      expect { runner.incoming(message) }.not_to change(Message, :count)
      expect(triage_session).to be_nil
    end

    it 'does not start on a campaign conversation' do
      conversation.update!(campaign: create(:campaign, account: account, inbox: inbox))
      message = incoming('Oi')

      runner.incoming(message)

      expect(triage_session).to be_nil
    end

    it 'does not start for a blocked contact' do
      conversation.contact.update!(blocked: true)
      message = incoming('Oi')

      runner.incoming(message)

      expect(triage_session).to be_nil
    end
  end

  describe '#incoming ordering guards' do
    before { start_flow }

    it 'ignores a message that predates the current prompt' do
      stale = conversation.messages.incoming.first

      expect { runner.incoming(stale) }.not_to change(Message, :count)
      expect(triage_session.attempts).to eq(0)
    end

    it 'performs exactly one transition when the same reply is delivered twice' do
      reply = incoming('Financeiro')
      runner.incoming(reply)

      expect { runner.incoming(reply) }.not_to change(Message, :count)
      expect(triage_session.path.length).to eq(1)
      expect(triage_session.current_step_id).to eq('financeiro')
    end

    it 'ignores messages once the session is terminal' do
      runner.incoming(incoming('Dúvidas Técnicas'))
      later = incoming('mais uma coisa')

      expect { runner.incoming(later) }.not_to change(Message, :count)
      expect(triage_session).to be_completed
      expect(triage_session.path.length).to eq(1)
    end
  end

  describe '#incoming on a step transition' do
    before { start_flow }

    it 'sends the child prompt and records the path' do
      reply = incoming('Financeiro')

      expect { runner.incoming(reply) }.to change(Message, :count).by(1)
      expect(last_prompt.content).to eq('Sobre o que você precisa falar?')
      expect(triage_session.current_step_id).to eq('financeiro')
      expect(triage_session.path.last).to include('step_id' => 'root', 'option_id' => 'financeiro')
    end

    it 'resets the attempts collected on the previous step' do
      runner.incoming(incoming('nao faco ideia'))
      expect(triage_session.attempts).to eq(1)

      runner.incoming(incoming('Financeiro'))

      expect(triage_session.attempts).to eq(0)
    end

    it 'moves the timeout token on to the new prompt' do
      runner.incoming(incoming('Financeiro'))

      expect(triage_session.timeout_token).to eq("#{flow.id}:#{flow.version}:#{last_prompt.id}")
    end
  end

  describe '#incoming on a route' do
    before { start_flow }

    it 'assigns the team, adds the labels and completes the session' do
      runner.incoming(incoming('Dúvidas Técnicas'))

      expect(conversation.reload.team_id).to eq(tech_team.id)
      expect(conversation.label_list).to include('ia_atendendo')
      expect(triage_session).to be_completed
      expect(triage_session.outcome).to eq('team_id' => tech_team.id, 'labels' => ['ia_atendendo'], 'status' => 'pending')
      expect(triage_session.finished_at).to be_present
      expect(triage_session.timeout_token).to be_nil
    end

    it 'leaves the conversation pending when the route hands off to a bot' do
      runner.incoming(incoming('Dúvidas Técnicas'))

      expect(conversation.reload.status).to eq('pending')
    end

    it 'opens the conversation when the route sends it to humans' do
      runner.incoming(incoming('Dúvidas Gerais'))

      expect(conversation.reload.status).to eq('open')
      expect(conversation.team_id).to eq(general_team.id)
    end

    it 'sends no further prompt' do
      reply = incoming('Dúvidas Técnicas')

      expect { runner.incoming(reply) }.not_to change(Message, :count)
    end
  end

  describe '#incoming on a route that resolves' do
    before do
      definition = flow.definition.deep_dup
      definition['steps'][0]['options'][1]['next'] = {
        'type' => 'route', 'team_id' => general_team.id, 'labels' => [],
        'status' => 'resolved', 'message' => 'Obrigado pelo contato!'
      }
      flow.update!(definition: definition)
      start_flow
    end

    it 'resolves the conversation and sends the closing message' do
      reply = incoming('Dúvidas Gerais')

      expect { runner.incoming(reply) }.to change(Message, :count).by(1)
      expect(conversation.reload.status).to eq('resolved')
      expect(last_prompt.content).to eq('Obrigado pelo contato!')
      expect(triage_session).to be_completed
    end
  end

  describe '#incoming without a match' do
    before { start_flow }

    it 'reprompts the same step once with the no_match message' do
      reply = incoming('quero falar com alguem sobre outra coisa')

      expect { runner.incoming(reply) }.to change(Message, :count).by(1)
      expect(last_prompt.content).to eq("Não entendi.\n\nComo podemos ajudar?")
      expect(triage_session.attempts).to eq(1)
      expect(triage_session.current_step_id).to eq('root')
    end

    it 'applies the no_match action once the attempts run out' do
      3.times { runner.incoming(incoming('...')) }

      expect(triage_session).to be_fallback
      expect(triage_session.attempts).to eq(3)
      expect(conversation.reload.team_id).to eq(general_team.id)
      expect(conversation.status).to eq('open')
    end

    it 'stops reprompting on the last attempt' do
      2.times { runner.incoming(incoming('...')) }
      last = incoming('...')

      expect { runner.incoming(last) }.not_to change(Message, :count)
    end
  end

  describe '#widget_reply' do
    before { start_flow }

    it 'advances on the submitted option id' do
      runner.widget_reply(last_prompt, 'financeiro')

      expect(triage_session.current_step_id).to eq('financeiro')
      expect(triage_session.path.last).to include('option_id' => 'financeiro')
    end

    it 'ignores a reply submitted on a prompt we are no longer waiting on' do
      prompt = last_prompt
      runner.widget_reply(prompt, 'financeiro')

      expect { runner.widget_reply(prompt, 'tecnico') }.not_to change(Message, :count)
      expect(triage_session.current_step_id).to eq('financeiro')
      expect(triage_session.trace.last['event']).to eq('stale')
    end
  end

  describe '#agent_took_over' do
    before { start_flow }

    it 'abandons the session' do
      reply = create(:message, account: account, inbox: inbox, conversation: conversation,
                               message_type: :outgoing, sender: agent)

      runner.agent_took_over(reply)

      expect(triage_session).to be_abandoned
      expect(triage_session.finished_at).to be_present
      expect(triage_session.timeout_token).to be_nil
    end

    # The agent's reply ends the session, and the conversation the flow parked
    # in `pending` has to come back with it: nothing else is scheduled to
    # rescue it once the timeout token is cleared.
    it 'gives the conversation back to the team instead of leaving it in pending' do
      reply = create(:message, account: account, inbox: inbox, conversation: conversation,
                               message_type: :outgoing, sender: agent)

      expect(conversation.reload.status).to eq('pending')

      runner.agent_took_over(reply)

      expect(conversation.reload.status).to eq('open')
      expect(triage_session).to be_abandoned
    end

    it 'leaves a session that has already finished alone' do
      runner.incoming(incoming('Dúvidas Técnicas'))
      reply = create(:message, account: account, inbox: inbox, conversation: conversation,
                               message_type: :outgoing, sender: agent)

      runner.agent_took_over(reply)

      expect(triage_session).to be_completed
    end
  end

  # An agent opening the conversation afterwards has to be able to read what
  # the flow did to it. Without a branch for TriageFlow, Current.executed_by
  # falls through ActivityMessageHandler and the status changes leave no trace
  # at all, while the assignee line is attributed to "Automation System".
  describe 'the activity trail it leaves behind' do
    def activity_contents(&)
      perform_enqueued_jobs(only: Conversations::ActivityMessageJob, &)
      conversation.messages.reload.where(message_type: :activity).map(&:content)
    end

    it 'explains the handover and the routing in the timeline' do
      contents = activity_contents do
        start_flow
        runner.incoming(incoming('Dúvidas Técnicas'))
      end

      expect(contents).to include(a_string_including('pending').and(a_string_including('Triage')))
      expect(contents).not_to include(a_string_including('Automation System'))
    end
  end

  describe 'shadow mode' do
    let(:flow) do
      create(:triage_flow, account: account, inbox: inbox, enabled: true, mode: :shadow,
                           tech_team: tech_team, general_team: general_team)
    end

    it 'opens a session without sending anything or touching the conversation' do
      message = incoming('Oi')

      expect { runner.incoming(message) }.not_to change(Message, :count)
      expect(conversation.reload.status).to eq('open')
      expect(conversation.assignee_id).to eq(agent.id)
      expect(triage_session.mode).to eq('shadow')
      expect(triage_session.current_step_id).to eq('root')
    end

    it 'pins the prompt to the triggering message so ordering still works' do
      message = incoming('Oi')
      runner.incoming(message)

      expect(triage_session.last_prompt_message_id).to eq(message.id)
      expect(triage_session.trace.last).to include('event' => 'prompt', 'step_id' => 'root', 'shadow' => true)
    end

    it 'never enqueues the timeout job' do
      start_flow

      expect(TriageFlows::TimeoutJob).not_to have_been_enqueued
    end

    it 'records the route it would have taken without applying it' do
      start_flow
      reply = incoming('Dúvidas Técnicas')

      expect { runner.incoming(reply) }.not_to change(Message, :count)
      expect(conversation.reload.team_id).to be_nil
      expect(conversation.status).to eq('open')
      expect(conversation.label_list).to be_empty
      expect(triage_session).to be_completed
      expect(triage_session.outcome).to eq('team_id' => tech_team.id, 'labels' => ['ia_atendendo'], 'status' => 'pending')
    end
  end

  describe 'error handling' do
    it 'swallows failures so the event dispatcher is never broken' do
      allow(TriageFlows::PromptSender).to receive(:new).and_raise(StandardError, 'boom')
      allow(ChatwootExceptionTracker).to receive(:new).and_call_original
      message = incoming('Oi')

      expect { runner.incoming(message) }.not_to raise_error
      expect(ChatwootExceptionTracker).to have_received(:new)
      expect(triage_session).to be_nil
    end

    it 'clears Current.executed_by when it is done' do
      start_flow

      expect(Current.executed_by).to be_nil
    end
  end
end
