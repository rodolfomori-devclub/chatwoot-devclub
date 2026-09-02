require 'rails_helper'

RSpec.describe TriageFlows::PromptSender do
  let(:account) { create(:account) }
  let(:team) { create(:team, account: account) }

  def flow_for(inbox)
    create(:triage_flow, account: account, inbox: inbox, general_team: team, tech_team: team)
  end

  def session_for(inbox)
    conversation = create(:conversation, account: account, inbox: inbox)
    create(:triage_session, account: account, triage_flow: flow_for(inbox), conversation: conversation)
  end

  def prompt(session, prefix: nil)
    step = session.triage_flow.parsed.entry_step
    described_class.new(session).call(step, prefix: prefix)
  end

  context 'with a channel that renders a menu' do
    let(:inbox) { create(:inbox, account: account) }

    it 'sends an input_select carrying the options and the triage marker' do
      session = session_for(inbox)
      message = prompt(session)

      expect(message.content_type).to eq('input_select')
      expect(message.message_type).to eq('template')
      expect(message.content_attributes['items'].map { |item| item['value'] }).to eq(%w[tecnico gerais financeiro])
      expect(message.content_attributes['triage']).to include('step_id' => 'root', 'session_id' => session.id)
    end

    it 'puts the no-match reply above the question' do
      message = prompt(session_for(inbox), prefix: 'Não entendi.')

      expect(message.content).to eq("Não entendi.\n\nComo podemos ajudar?")
    end
  end

  # A channel that cannot render input_select gets the options as text the
  # customer answers by typing "2". This is the branch an SMS or Telegram inbox
  # takes, and nothing else in the suite exercises it.
  context 'with a channel that cannot render a menu' do
    let(:inbox) { create(:channel_sms, account: account).inbox }

    it 'numbers the options into the body as plain text' do
      message = prompt(session_for(inbox))

      expect(message.content_type).to eq('text')
      expect(message.content).to eq("Como podemos ajudar?\n\n1. Dúvidas Técnicas\n2. Dúvidas Gerais\n3. Financeiro")
      expect(message.content_attributes).not_to have_key('items')
    end

    it 'still carries the triage marker so the reply can be matched' do
      session = session_for(inbox)
      message = prompt(session)

      expect(message.content_attributes['triage']).to include('step_id' => 'root', 'flow_id' => session.triage_flow_id)
    end
  end
end
