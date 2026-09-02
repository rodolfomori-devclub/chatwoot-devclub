require 'rails_helper'

# The widget never sends a second incoming message when the visitor picks an
# option: it PATCHes submitted_values onto the menu message itself. That path
# has its own listener branch, its own staleness window and — unlike WhatsApp —
# an inbox with no bot, where round robin has already handed the conversation to
# an agent by the time the flow gets to look at it. So it gets its own round trip
# driven through the real widget endpoints.
RSpec.describe 'Triage flow web widget round trip', type: :request do
  let(:account) { create(:account) }
  let!(:teams) do
    { tecnico: create(:team, account: account, name: 'Suporte Técnico'),
      geral: create(:team, account: account, name: 'Atendimento Geral'),
      renovacao: create(:team, account: account, name: 'Renovação'),
      financeiro: create(:team, account: account, name: 'Financeiro') }
  end
  let(:web_widget) { create(:channel_widget, account: account) }
  let(:inbox) { web_widget.inbox }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:contact) { create(:contact, account: account, email: nil) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:token) { Widget::TokenService.new(payload: { source_id: contact_inbox.source_id, inbox_id: inbox.id }).generate_token }
  let(:flow) { TriageFlows::SeedService.new(account: account, inbox: inbox).perform }

  before do
    # A real round robin target, so "assignee_id is nil" proves the flow cleared
    # it rather than proving nobody was available.
    create(:inbox_member, user: agent, inbox: inbox)
    OnlineStatusTracker.update_presence(account.id, 'User', agent.id)
    account.enable_features!('triage_flows')
    flow.update!(enabled: true, mode: :live)
  end

  # `at:` keeps delayed jobs (TriageFlows::TimeoutJob, the reply mailer) queued
  # while every immediate job runs for real.
  def say(content)
    perform_enqueued_jobs(at: Time.current) do
      post api_v1_widget_messages_url,
           params: { website_token: web_widget.website_token, message: { content: content, timestamp: Time.current } },
           headers: { 'X-Auth-Token' => token },
           as: :json
    end
  end

  def choose(message, title, value)
    perform_enqueued_jobs(at: Time.current) do
      patch api_v1_widget_message_url(message.id),
            params: { website_token: web_widget.website_token, message: { submitted_values: [{ title: title, value: value }] } },
            headers: { 'X-Auth-Token' => token },
            as: :json
    end
  end

  def conversation
    inbox.conversations.reorder(:id).last
  end

  def menus
    conversation.messages.where(content_type: 'input_select').reorder(:id)
  end

  def session
    TriageSession.find_by(conversation_id: conversation.id)
  end

  it 'greets the visitor with the menu and parks the conversation as pending' do
    say('oi')

    expect(response).to have_http_status(:success)
    expect(menus.count).to eq(1)
    expect(menus.last.content_attributes['items'].pluck('title')).to eq(['Dúvidas Técnicas', 'Dúvidas Gerais', 'Financeiro'])
    expect(conversation.status).to eq('pending')
    expect(conversation.assignee_id).to be_nil
  end

  it 'would have been auto-assigned and left open without the flow' do
    flow.update!(enabled: false)

    say('oi')

    expect(menus.count).to eq(0)
    expect(conversation.assignee_id).to eq(agent.id)
    expect(conversation.status).to eq('open')
  end

  it 'sends the second level menu when the visitor submits Financeiro' do
    say('oi')
    choose(menus.last, 'Financeiro', 'financeiro')

    expect(menus.count).to eq(2)
    expect(menus.last.content_attributes['items'].pluck('title')).to eq(['Renovação', 'Comprar Formação', 'Outros assuntos'])
    expect(menus.last.content_attributes.dig('triage', 'step_id')).to eq('financeiro')
    expect(session.current_step_id).to eq('financeiro')
  end

  it 'ignores a submission replayed on an already answered menu' do
    say('oi')
    choose(menus.first, 'Financeiro', 'financeiro')

    choose(menus.first, 'Dúvidas Gerais', 'gerais')

    expect(menus.count).to eq(2)
    expect(session.current_step_id).to eq('financeiro')
    expect(session.status).to eq('active')
    expect(conversation.team_id).to be_nil
  end

  it 'ignores a submission on a menu that a re-prompt has superseded' do
    say('oi')
    stale_menu = menus.last
    say('nao sei bem o que eu quero')
    expect(menus.count).to eq(2)

    choose(stale_menu, 'Financeiro', 'financeiro')

    expect(menus.count).to eq(2)
    expect(session.current_step_id).to eq('root')
    expect(conversation.team_id).to be_nil
  end

  it 'routes to the renovacao team once the visitor submits Renovação' do
    say('oi')
    choose(menus.last, 'Financeiro', 'financeiro')
    choose(menus.last, 'Renovação', 'renovacao')

    expect(conversation.team_id).to eq(teams[:renovacao].id)
    expect(conversation.status).to eq('open')
    expect(session.status).to eq('completed')
    expect(session.outcome['team_id']).to eq(teams[:renovacao].id)
  end
end
