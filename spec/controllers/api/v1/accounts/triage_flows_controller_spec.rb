require 'rails_helper'

RSpec.describe 'Triage Flows API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:team) { create(:team, account: account) }
  let(:inbox) { create(:inbox, account: account) }

  def route_to(team_id, status: 'open', labels: [])
    { 'type' => 'route', 'team_id' => team_id, 'labels' => labels, 'status' => status }
  end

  # Mirrors the shape the dashboard posts: a nested step, a labelled route and
  # both fallback branches.
  def definition_for(team_id)
    {
      'entry_step_id' => 'root',
      'steps' => [
        { 'id' => 'root', 'prompt' => 'Como podemos ajudar?', 'options' => [
          { 'id' => 'tecnico', 'title' => 'Dúvidas Técnicas', 'next' => route_to(team_id, status: 'pending', labels: ['ia_atendendo']) },
          { 'id' => 'financeiro', 'title' => 'Financeiro', 'next' => { 'type' => 'step', 'step_id' => 'financeiro' } }
        ] },
        { 'id' => 'financeiro', 'prompt' => 'Sobre o que você precisa falar?', 'options' => [
          { 'id' => 'renovacao', 'title' => 'Renovação', 'next' => route_to(team_id) }
        ] }
      ],
      'no_match' => { 'message' => 'Não entendi.', 'max_attempts' => 3, 'then' => route_to(team_id) },
      'timeout' => { 'minutes' => 30, 'then' => route_to(team_id) }
    }
  end

  before { account.enable_features!('triage_flows') }

  describe 'GET /api/v1/accounts/{account.id}/triage_flows' do
    let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox) }

    it 'returns unauthorized for an unauthenticated user' do
      get "/api/v1/accounts/#{account.id}/triage_flows"

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns unauthorized for an agent' do
      get "/api/v1/accounts/#{account.id}/triage_flows", headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the flows of the account for an admin' do
      get "/api/v1/accounts/#{account.id}/triage_flows", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      payload = response.parsed_body['payload']
      expect(payload.length).to eq(1)
      expect(payload.first['id']).to eq(triage_flow.id)
      expect(payload.first['mode']).to eq('shadow')
      expect(payload.first['inbox']).to eq({ 'id' => inbox.id, 'name' => inbox.name, 'channel_type' => inbox.channel_type })
      expect(payload.first['warnings']).to eq([])
      expect(payload.first.keys).to contain_exactly('id', 'name', 'enabled', 'mode', 'version', 'definition', 'inbox', 'warnings', 'created_at',
                                                    'updated_at')
    end

    it 'returns forbidden when the feature is disabled' do
      account.disable_features!('triage_flows')

      get "/api/v1/accounts/#{account.id}/triage_flows", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body['error']).to eq(I18n.t('triage_flow.feature_not_enabled'))
    end

    it 'surfaces warnings for a flow pointing at a deleted team' do
      triage_flow.update!(definition: definition_for(team.id))
      team.destroy!

      get "/api/v1/accounts/#{account.id}/triage_flows", headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['payload'].first['warnings']).to include({ 'type' => 'missing_team', 'team_id' => team.id })
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/triage_flows/:id' do
    let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox) }

    it 'returns unauthorized for an unauthenticated user' do
      get "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}"

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns unauthorized for an agent' do
      get "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}", headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns the flow for an admin' do
      get "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).to eq(triage_flow.id)
      expect(response.parsed_body['definition']).to eq(triage_flow.definition)
    end

    it 'returns not found for a flow of another account' do
      other_flow = create(:triage_flow)

      get "/api/v1/accounts/#{account.id}/triage_flows/#{other_flow.id}", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/triage_flows' do
    let(:payload) do
      { triage_flow: { name: 'DevClub Triage', inbox_id: inbox.id, enabled: true, mode: 'shadow', definition: definition_for(team.id) } }
    end

    it 'returns unauthorized for an unauthenticated user' do
      post "/api/v1/accounts/#{account.id}/triage_flows", params: payload, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns unauthorized for an agent' do
      post "/api/v1/accounts/#{account.id}/triage_flows", params: payload, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'creates the flow for an admin' do
      post "/api/v1/accounts/#{account.id}/triage_flows", params: payload, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['name']).to eq('DevClub Triage')
      expect(response.parsed_body['enabled']).to be(true)
      expect(response.parsed_body['version']).to eq(1)
      expect(response.parsed_body['inbox']['id']).to eq(inbox.id)
    end

    # A strong-params slip here truncates the tree instead of failing loudly.
    it 'round-trips the whole definition, nested arrays included' do
      post "/api/v1/accounts/#{account.id}/triage_flows", params: payload, headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['definition']).to eq(definition_for(team.id))
      expect(TriageFlow.last.definition).to eq(definition_for(team.id))
    end

    it 'returns the validator message when the definition is invalid' do
      broken = definition_for(team.id)
      broken['steps'][0]['options'][1]['next'] = { 'type' => 'step', 'step_id' => 'inexistente' }

      post "/api/v1/accounts/#{account.id}/triage_flows",
           params: { triage_flow: { name: 'Broken', inbox_id: inbox.id, definition: broken } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['errors']['definition']).to include(I18n.t('triage_flow.errors.unknown_step_ref', step_id: 'inexistente'))
    end

    it 'returns forbidden when the feature is disabled' do
      account.disable_features!('triage_flows')

      post "/api/v1/accounts/#{account.id}/triage_flows", params: payload, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/triage_flows/:id' do
    let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox) }

    it 'returns unauthorized for an agent' do
      patch "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}",
            params: { triage_flow: { name: 'Renamed' } }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'updates name, mode and enabled without touching the definition' do
      patch "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}",
            params: { triage_flow: { name: 'Renamed', enabled: true, mode: 'live' } },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['name']).to eq('Renamed')
      expect(response.parsed_body['mode']).to eq('live')
      expect(response.parsed_body['definition']).to eq(triage_flow.definition)
    end

    it 'bumps the version when the definition changes' do
      patch "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}",
            params: { triage_flow: { definition: definition_for(team.id) } },
            headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['version']).to eq(2)
      expect(response.parsed_body['definition']).to eq(definition_for(team.id))
    end

    it 'ignores inbox_id' do
      other_inbox = create(:inbox, account: account)

      patch "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}",
            params: { triage_flow: { inbox_id: other_inbox.id } }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(triage_flow.reload.inbox_id).to eq(inbox.id)
    end

    it 'returns the validator message when the new definition is invalid' do
      patch "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}",
            params: { triage_flow: { definition: definition_for(team.id).merge('entry_step_id' => 'nope') } },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['errors']['definition']).to include(I18n.t('triage_flow.errors.entry_step_unknown', step_id: 'nope'))
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/triage_flows/:id' do
    let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox) }

    it 'returns unauthorized for an agent' do
      delete "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}", headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'deletes the flow for an admin' do
      delete "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(TriageFlow.exists?(triage_flow.id)).to be(false)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/triage_flows/:id/clone' do
    let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox, name: 'DevClub Triage', enabled: true, mode: :live) }
    let(:target_inbox) { create(:inbox, account: account) }

    it 'returns unauthorized for an agent' do
      post "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}/clone",
           params: { inbox_id: target_inbox.id }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'clones the definition onto another inbox as a disabled shadow flow' do
      post "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}/clone",
           params: { inbox_id: target_inbox.id }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).not_to eq(triage_flow.id)
      expect(response.parsed_body['name']).to eq('DevClub Triage (copy)')
      expect(response.parsed_body['enabled']).to be(false)
      expect(response.parsed_body['mode']).to eq('shadow')
      expect(response.parsed_body['inbox']['id']).to eq(target_inbox.id)
      expect(response.parsed_body['definition']).to eq(triage_flow.definition)
    end

    it 'rejects a clone onto an inbox that already has a flow' do
      create(:triage_flow, account: account, inbox: target_inbox)

      post "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}/clone",
           params: { inbox_id: target_inbox.id }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['errors']).to have_key('inbox_id')
    end

    it 'rejects a widget flow whose titles break the WhatsApp button limit' do
      whatsapp_inbox = create(:inbox, account: account,
                                      channel: create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false))
      definition = definition_for(team.id)
      definition['steps'][0]['options'][0]['title'] = 'Dúvidas Técnicas sobre o curso'

      triage_flow.update!(definition: definition)

      post "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}/clone",
           params: { inbox_id: whatsapp_inbox.id }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['errors']['definition']).to include(I18n.t('triage_flow.errors.option_title_too_long', step_id: 'root', max: 20))
    end
  end

  # The dashboard store is proven to hand axios this definition untouched by
  # app/javascript/dashboard/store/modules/specs/triageFlows/roundTrip.spec.js.
  # This is the other half of that path: the same bytes, posted the way the
  # store posts them, have to survive strong params and jsonb unchanged.
  describe 'definition round trip' do
    let(:fixture) { JSON.parse(Rails.root.join('spec/fixtures/triage_flows/round_trip_flow.json').read) }
    let(:definition) { resolve_team_ids(fixture['definition'], team.id) }

    # The fixture cannot know a team id, so it carries 0 as a placeholder.
    def resolve_team_ids(node, team_id)
      case node
      when Hash then node.to_h { |key, value| [key, key == 'team_id' ? team_id : resolve_team_ids(value, team_id)] }
      when Array then node.map { |value| resolve_team_ids(value, team_id) }
      else node
      end
    end

    def create_flow
      post "/api/v1/accounts/#{account.id}/triage_flows",
           params: { triage_flow: { name: fixture['name'], inbox_id: inbox.id, enabled: fixture['enabled'],
                                    mode: fixture['mode'], definition: definition } },
           headers: admin.create_new_auth_token, as: :json
    end

    it 'persists a two-level definition key for key' do
      create_flow

      expect(response).to have_http_status(:success)
      expect(TriageFlow.last.definition).to eq(definition)
    end

    it 'keeps nested arrays, including the empty ones strong params like to drop' do
      create_flow
      stored = TriageFlow.last.definition

      expect(stored['steps'].map { |step| step['options'].length }).to eq([2, 2])
      expect(stored['steps'][0]['options'][0]['next']['labels']).to eq(%w[ia_atendendo suporte_n1])
      expect(stored['steps'][1]['options'][0]['next']['labels']).to eq([])
      expect(stored['no_match']['then']['labels']).to eq([])
    end

    it 'keeps the snake_case keys and value types the engine reads' do
      create_flow
      stored = TriageFlow.last.definition

      expect(stored.keys).to contain_exactly('entry_step_id', 'steps', 'no_match', 'timeout')
      expect(stored['steps'][0]['options'][1]['next']).to eq({ 'type' => 'step', 'step_id' => 'financeiro' })
      expect(stored['steps'][0]['options'][0]['next']['team_id']).to eq(team.id)
      expect(stored['no_match']['max_attempts']).to eq(3)
      expect(stored['timeout']['minutes']).to eq(30)
    end

    it 'returns the same definition on the next read' do
      create_flow
      flow_id = response.parsed_body['id']

      get "/api/v1/accounts/#{account.id}/triage_flows/#{flow_id}", headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['definition']).to eq(definition)
    end

    it 'is unchanged by a save that does not touch it' do
      create_flow
      flow_id = response.parsed_body['id']

      patch "/api/v1/accounts/#{account.id}/triage_flows/#{flow_id}",
            params: { triage_flow: { name: 'Renamed' } }, headers: admin.create_new_auth_token, as: :json

      expect(TriageFlow.find(flow_id).definition).to eq(definition)
      expect(response.parsed_body['version']).to eq(1)
    end

    it 'survives a re-save of what the read handed back' do
      create_flow
      flow_id = response.parsed_body['id']
      echoed = response.parsed_body['definition']

      patch "/api/v1/accounts/#{account.id}/triage_flows/#{flow_id}",
            params: { triage_flow: { definition: echoed } }, headers: admin.create_new_auth_token, as: :json

      expect(TriageFlow.find(flow_id).definition).to eq(definition)
    end
  end

  describe 'clone safety' do
    let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox) }
    let(:target_inbox) { create(:inbox, account: account) }

    def whatsapp_inbox
      create(:inbox, account: account,
                     channel: create(:channel_whatsapp, account: account, sync_templates: false, validate_provider_config: false))
    end

    def clone_to(target)
      post "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}/clone",
           params: { inbox_id: target.id }, headers: admin.create_new_auth_token, as: :json
    end

    it 'lands as a disabled shadow draft even when the source is live and enabled' do
      triage_flow.update!(enabled: true, mode: :live)

      clone_to(target_inbox)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to include('enabled' => false, 'mode' => 'shadow')
      expect(TriageFlow.last).to have_attributes(enabled: false, mode: 'shadow')
    end

    it 'accepts a widget flow whose longest title is exactly the WhatsApp button cap' do
      definition = triage_flow.definition
      definition['steps'][0]['options'][0]['title'] = 'a' * 20
      triage_flow.update!(definition: definition)

      clone_to(whatsapp_inbox)

      expect(response).to have_http_status(:success)
    end

    it 'rejects a widget flow one character over the WhatsApp button cap' do
      definition = triage_flow.definition
      definition['steps'][0]['options'][0]['title'] = 'a' * 21
      triage_flow.update!(definition: definition)

      clone_to(whatsapp_inbox)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['errors']['definition']).to include(I18n.t('triage_flow.errors.option_title_too_long', step_id: 'root', max: 20))
      expect(TriageFlow.count).to eq(1)
    end
  end

  # Shapes the dashboard could never build, posted straight to the API. The
  # parser used to walk into NoMethodError on any of them and answer 500; a
  # malformed definition has to be an ordinary 422 like every other bad save.
  describe 'POST /api/v1/accounts/{account.id}/triage_flows with a malformed definition' do
    def post_flow(definition, mode: 'shadow')
      post "/api/v1/accounts/#{account.id}/triage_flows",
           params: { triage_flow: { name: 'Malformed', inbox_id: inbox.id, mode: mode, definition: definition } },
           headers: admin.create_new_auth_token, as: :json
    end

    def broken_definition(&)
      definition_for(team.id).tap(&)
    end

    def definition_errors
      response.parsed_body['errors']['definition']
    end

    it 'reads a scalar option transition as no destination' do
      post_flow(broken_definition { |definition| definition['steps'][0]['options'][0]['next'] = 'route' })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.transition_missing', step_id: 'root'))
    end

    it 'reads an array option transition as no destination' do
      post_flow(broken_definition { |definition| definition['steps'][0]['options'][0]['next'] = [{ 'type' => 'route' }] })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.transition_missing', step_id: 'root'))
    end

    it 'reads a scalar step as an empty step' do
      post_flow(broken_definition { |definition| definition['steps'] << 'financeiro' })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.invalid_step_id', step_id: ''))
    end

    it 'reads a scalar option as an empty option' do
      post_flow(broken_definition { |definition| definition['steps'][0]['options'] << 'tecnico' })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.invalid_option_id', option_id: ''))
    end

    it 'reads a scalar steps list as one unusable step' do
      post_flow(broken_definition { |definition| definition['steps'] = 'root' })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.entry_step_unknown', step_id: 'root'))
    end

    it 'reads a scalar no_match as no fallback' do
      post_flow(broken_definition { |definition| definition['no_match'] = 'route' })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.no_match_action_missing'))
    end

    it 'reads a scalar timeout as no timeout' do
      post_flow(broken_definition { |definition| definition['timeout'] = '30' }, mode: 'live')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.timeout_required_when_live'))
    end

    it 'reads an object where a number belongs as out of range' do
      post_flow(broken_definition do |definition|
        definition['no_match']['max_attempts'] = { 'value' => 3 }
        definition['timeout']['minutes'] = { 'value' => 30 }
      end)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.max_attempts_range'), I18n.t('triage_flow.errors.timeout_range'))
    end

    it 'reads an object where a team id belongs as an unknown team' do
      post_flow(broken_definition { |definition| definition['steps'][0]['options'][0]['next']['team_id'] = { 'id' => team.id } })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.unknown_team', team_id: 0))
    end

    it 'reads a list where the definition belongs as no definition at all' do
      post_flow([{ 'entry_step_id' => 'root', 'steps' => [] }])

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.no_steps'))
    end

    it 'reads a scalar definition as no definition at all' do
      post_flow('route')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(definition_errors).to include(I18n.t('triage_flow.errors.no_steps'))
      expect(TriageFlow.count).to eq(0)
    end

    # One level up from the definition: `params.require` hands a String or an
    # Array straight back and `.permit` raises on it, so the envelope needs the
    # same treatment as the tree inside it.
    it 'refuses a scalar envelope with a 422' do
      post "/api/v1/accounts/#{account.id}/triage_flows",
           params: { triage_flow: 'oops' }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['errors']['triage_flow']).to include(I18n.t('triage_flow.errors.invalid_payload'))
    end

    it 'refuses an array envelope with a 422' do
      post "/api/v1/accounts/#{account.id}/triage_flows",
           params: { triage_flow: [1, 2] }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(TriageFlow.count).to eq(0)
    end
  end

  # The missing-team warnings render per row, so without preloading the index
  # repeats one identical team lookup for every inbox that has a flow.
  describe 'GET index with several flows' do
    it 'looks the account teams up once, not once per flow' do
      3.times { create(:triage_flow, account: account, inbox: create(:inbox, account: account)) }
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
        queries << payload[:sql]
      end

      get "/api/v1/accounts/#{account.id}/triage_flows", headers: admin.create_new_auth_token, as: :json
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(response).to have_http_status(:success)
      expect(queries.count { |sql| sql.include?('FROM "teams"') }).to be <= 1
    end
  end

  # `definition: {}` means "clear the tree". Skipping a blank key answered 200
  # while the engine kept serving the old menu, so the operator would believe
  # the menu was down when it was still talking to customers.
  describe 'PATCH with an explicitly empty definition' do
    let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox) }

    it 'answers 422 instead of silently keeping the old tree' do
      patch "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}",
            params: { triage_flow: { name: 'renamed', definition: {} } },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['errors']['definition']).to include(I18n.t('triage_flow.errors.no_steps'))
      expect(triage_flow.reload.name).not_to eq('renamed')
    end

    it 'still allows an update that does not mention the definition' do
      patch "/api/v1/accounts/#{account.id}/triage_flows/#{triage_flow.id}",
            params: { triage_flow: { name: 'renamed' } },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(triage_flow.reload.name).to eq('renamed')
    end
  end

  describe 'with the account feature flag off' do
    let!(:triage_flow) { create(:triage_flow, account: account, inbox: inbox) }
    let(:target_inbox) { create(:inbox, account: account) }
    let(:headers) { admin.create_new_auth_token }
    let(:base_url) { "/api/v1/accounts/#{account.id}/triage_flows" }

    before { account.disable_features!('triage_flows') }

    it 'answers 403 on every action and changes nothing' do
      requests = {
        index: -> { get base_url, headers: headers, as: :json },
        show: -> { get "#{base_url}/#{triage_flow.id}", headers: headers, as: :json },
        create: lambda {
          post base_url, params: { triage_flow: { name: 'New', inbox_id: target_inbox.id, definition: definition_for(team.id) } },
                         headers: headers, as: :json
        },
        update: -> { patch "#{base_url}/#{triage_flow.id}", params: { triage_flow: { name: 'Renamed' } }, headers: headers, as: :json },
        destroy: -> { delete "#{base_url}/#{triage_flow.id}", headers: headers, as: :json },
        clone: -> { post "#{base_url}/#{triage_flow.id}/clone", params: { inbox_id: target_inbox.id }, headers: headers, as: :json }
      }

      refused = requests.filter_map do |action, request|
        request.call
        next if response.forbidden? && response.parsed_body['error'] == I18n.t('triage_flow.feature_not_enabled')

        "#{action}: #{response.status} #{response.parsed_body['error']}"
      end

      expect(refused).to eq([])
      expect(TriageFlow.count).to eq(1)
      expect(triage_flow.reload.name).not_to eq('Renamed')
    end
  end
end
