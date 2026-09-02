require 'rails_helper'

# The engine is unit-tested elsewhere. This spec exists because the three failed
# cutovers all had green unit tests: what broke was the real channel path —
# duplicate menus, a tap that scored as a wrong answer, a payload Meta rejected.
# So nothing here is stubbed except Meta itself: the customer's webhook payload
# goes through Whatsapp::IncomingMessageWhatsappCloudService and the assertions
# are made on the JSON body that actually leaves for graph.facebook.com.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Triage flow WhatsApp round trip' do
  let(:account) { create(:account) }
  let!(:teams) do
    { tecnico: create(:team, account: account, name: 'Suporte Técnico'),
      geral: create(:team, account: account, name: 'Atendimento Geral'),
      renovacao: create(:team, account: account, name: 'Renovação'),
      financeiro: create(:team, account: account, name: 'Financeiro') }
  end
  # whatsapp_cloud is the provider DevClub runs, and the only one that talks to
  # graph.facebook.com with the interactive payload this flow depends on.
  let(:channel) { create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false) }
  let(:inbox) { channel.inbox }
  let(:flow) { TriageFlows::SeedService.new(account: account, inbox: inbox).perform }
  let(:meta_requests) { [] }
  let(:wa_id) { '2423423243' }

  before do
    account.enable_features!('triage_flows')
    flow.update!(enabled: true, mode: :live)

    stub_request(:post, /graph\.facebook\.com/).to_return do |request|
      meta_requests << JSON.parse(request.body)
      { status: 200, body: { messages: [{ id: "wamid.out#{meta_requests.size}" }] }.to_json,
        headers: { 'Content-Type' => 'application/json' } }
    end
  end

  # `at:` keeps delayed jobs (the 30 minute TriageFlows::TimeoutJob, the
  # conversation reply mailer) queued instead of firing them inline, while every
  # immediate job — EventDispatcherJob, SendReplyJob — runs for real.
  def deliver(message)
    perform_enqueued_jobs(at: Time.current) do
      Whatsapp::IncomingMessageWhatsappCloudService.new(inbox: inbox, params: cloud_envelope(message)).perform
    end
  end

  def send_text(body)
    deliver('from' => wa_id, 'id' => "wamid.#{SecureRandom.hex(8)}", 'text' => { 'body' => body },
            'timestamp' => '1633034394', 'type' => 'text')
  end

  # A button or list tap arrives as a brand new incoming message whose content is
  # the option TITLE — Chatwoot throws the reply id away.
  def tap_option(title)
    deliver('from' => wa_id, 'id' => "wamid.#{SecureRandom.hex(8)}",
            'interactive' => { 'button_reply' => { 'id' => '1', 'title' => title }, 'type' => 'button_reply' },
            'timestamp' => '1633034394', 'type' => 'interactive')
  end

  # Four or more options render as a list, and Meta then answers with
  # list_reply rather than button_reply. Same shape, different key.
  def tap_list_option(title)
    deliver('from' => wa_id, 'id' => "wamid.#{SecureRandom.hex(8)}",
            'interactive' => { 'list_reply' => { 'id' => '1', 'title' => title }, 'type' => 'list_reply' },
            'timestamp' => '1633034394', 'type' => 'interactive')
  end

  def cloud_envelope(message)
    {
      'object' => 'whatsapp_business_account',
      'entry' => [{ 'changes' => [{ 'value' => {
        'contacts' => [{ 'profile' => { 'name' => 'Aluno DevClub' }, 'wa_id' => wa_id }],
        'messages' => [message]
      } }] }]
    }.with_indifferent_access
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

  def last_action
    JSON.parse(meta_requests.last['interactive']['action'])
  end

  it 'answers the opening message with exactly one interactive menu' do
    send_text('Oi')

    expect(menus.count).to eq(1)
    expect(meta_requests.size).to eq(1)
    expect(meta_requests.last['type']).to eq('interactive')
    expect(meta_requests.last['interactive']['type']).to eq('button')
    expect(last_action['buttons'].map { |button| button['reply']['title'] })
      .to eq(['Dúvidas Técnicas', 'Dúvidas Gerais', 'Financeiro'])
  end

  it 'takes the conversation off the agent queue while the menu is open' do
    send_text('Oi')

    expect(conversation.status).to eq('pending')
    expect(conversation.assignee_id).to be_nil
    expect(session.status).to eq('active')
    expect(session.current_step_id).to eq('root')
  end

  it 'sends the second level menu when the customer taps Financeiro' do
    send_text('Oi')
    tap_option('Financeiro')

    expect(menus.count).to eq(2)
    expect(menus.last.content_attributes['items'].pluck('title')).to eq(['Renovação', 'Comprar Formação', 'Outros assuntos'])
    expect(menus.last.content_attributes.dig('triage', 'step_id')).to eq('financeiro')
    expect(session.current_step_id).to eq('financeiro')
    expect(session.status).to eq('active')
  end

  it 'routes to the renovacao team once the customer picks Renovação' do
    send_text('Oi')
    tap_option('Financeiro')
    tap_option('Renovação')

    expect(conversation.team_id).to eq(teams[:renovacao].id)
    expect(conversation.status).to eq('open')
    expect(session.status).to eq('completed')
    expect(session.outcome['team_id']).to eq(teams[:renovacao].id)
  end

  it 'labels the Comprar Formação leaf without changing its team' do
    send_text('Oi')
    tap_option('Financeiro')
    tap_option('Comprar Formação')

    expect(conversation.team_id).to eq(teams[:renovacao].id)
    expect(conversation.label_list).to include('comprar_formacao')
    expect(session.status).to eq('completed')
  end

  it 'routes Outros assuntos to the financeiro team' do
    send_text('Oi')
    tap_option('Financeiro')
    tap_option('Outros assuntos')

    expect(conversation.team_id).to eq(teams[:financeiro].id)
    expect(session.status).to eq('completed')
  end

  it 'hands Dúvidas Técnicas to the tech team, labelled and pending' do
    send_text('Oi')
    tap_option('Dúvidas Técnicas')

    expect(conversation.team_id).to eq(teams[:tecnico].id)
    expect(conversation.status).to eq('pending')
    expect(conversation.label_list).to include('ia_atendendo')
    expect(session.status).to eq('completed')
  end

  it 'treats a typed index like a tap on that option' do
    send_text('Oi')
    send_text('2')

    expect(conversation.team_id).to eq(teams[:geral].id)
    expect(conversation.status).to eq('open')
    expect(session.status).to eq('completed')
  end

  it 'falls back to the general team after three unmatched replies' do
    send_text('Oi')
    3.times { |attempt| send_text("por favor me ajuda #{attempt}") }

    # entry menu + one re-prompt per failed attempt that still had a retry left
    expect(menus.count).to eq(3)
    expect(conversation.team_id).to eq(teams[:geral].id)
    expect(conversation.status).to eq('open')
    expect(session.status).to eq('fallback')
  end

  it 'ignores further messages once the session is finished' do
    send_text('Oi')
    tap_option('Dúvidas Gerais')
    expect(menus.count).to eq(1)

    send_text('mais uma pergunta')

    expect(menus.count).to eq(1)
    expect(session.status).to eq('completed')
  end

  it 'renders a list instead of buttons when a step has more than three options' do
    definition = flow.definition.deep_dup
    definition['steps'].first['options'] << { 'id' => 'outros', 'title' => 'Outros assuntos',
                                              'next' => { 'type' => 'route', 'team_id' => teams[:geral].id, 'labels' => [], 'status' => 'open' } }
    flow.update!(definition: definition)

    send_text('Oi')

    expect(meta_requests.last['interactive']['type']).to eq('list')
    expect(last_action['sections'].first['rows'].pluck('title')).to include('Outros assuntos')
  end

  it 'routes a list row tap the same way it routes a button tap' do
    definition = flow.definition.deep_dup
    definition['steps'].first['options'] << { 'id' => 'outros', 'title' => 'Outros assuntos',
                                              'next' => { 'type' => 'route', 'team_id' => teams[:geral].id, 'labels' => [], 'status' => 'open' } }
    flow.update!(definition: definition)
    send_text('Oi')

    tap_list_option('Outros assuntos')

    expect(session.status).to eq('completed')
    expect(session.outcome['team_id']).to eq(teams[:geral].id)
    expect(conversation.reload.team_id).to eq(teams[:geral].id)
  end
end
# rubocop:enable RSpec/DescribeClass
