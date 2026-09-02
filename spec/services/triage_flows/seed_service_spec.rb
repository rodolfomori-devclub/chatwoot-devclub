require 'rails_helper'

RSpec.describe TriageFlows::SeedService do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }

  def seed
    described_class.new(account: account, inbox: inbox).perform
  end

  def team_names_by_option(flow)
    by_id = account.teams.index_by(&:id)
    flow.parsed.steps.flat_map(&:options).filter_map do |option|
      next unless option.next.is_a?(TriageFlows::Definition::Route)

      [option.title, by_id[option.next.team_id]&.name]
    end.to_h
  end

  describe 'team resolution' do
    # The real DevClub teams all start with "suporte". A single greedy
    # substring pass sent the `geral` role to "suporte técnico" — every
    # fallback and timeout would have landed in the wrong queue in production.
    context 'with the production team names' do
      before do
        ['suporte técnico', 'suporte geral', 'suporte financeiro', 'suporte renovação'].each do |name|
          create(:team, account: account, name: name)
        end
      end

      it 'routes each option to the team that matches its role' do
        expect(team_names_by_option(seed)).to eq(
          'Dúvidas Técnicas' => 'suporte técnico',
          'Dúvidas Gerais' => 'suporte geral',
          'Renovação' => 'suporte renovação',
          'Comprar Formação' => 'suporte renovação',
          'Outros assuntos' => 'suporte financeiro'
        )
      end

      it 'routes no-match and timeout to the general team, never to técnico' do
        definition = seed.parsed
        general = account.teams.find_by(name: 'suporte geral')
        expect(definition.no_match.action.team_id).to eq(general.id)
        expect(definition.timeout.action.team_id).to eq(general.id)
      end
    end

    context 'with exactly named teams' do
      before do
        ['Suporte Técnico', 'Atendimento Geral', 'Renovação', 'Financeiro'].each do |name|
          create(:team, account: account, name: name)
        end
      end

      # Team#name is stored downcased, so compare against the persisted form.
      it 'prefers the exact match' do
        expect(team_names_by_option(seed)['Dúvidas Gerais']).to eq('atendimento geral')
      end
    end

    context 'with a suffixed team name' do
      before do
        ['Suporte Técnico', 'Geral DevClub', 'Renovação', 'Financeiro DevClub'].each do |name|
          create(:team, account: account, name: name)
        end
      end

      it 'still matches on a whole word' do
        names = team_names_by_option(seed)
        expect(names['Dúvidas Gerais']).to eq('geral devclub')
        expect(names['Outros assuntos']).to eq('financeiro devclub')
      end
    end

    context 'when a role has no team' do
      before { create(:team, account: account, name: 'Suporte Técnico') }

      it 'raises naming the missing roles' do
        expect { seed }.to raise_error(described_class::MissingTeamError, /geral/)
      end
    end
  end

  describe 'the seeded flow' do
    before do
      ['suporte técnico', 'suporte geral', 'suporte financeiro', 'suporte renovação'].each do |name|
        create(:team, account: account, name: name)
      end
    end

    it 'is valid and free of warnings' do
      flow = seed
      expect(flow).to be_valid
      expect(flow.warnings).to be_empty
    end

    it 'starts disabled and in shadow mode' do
      flow = seed
      expect(flow.enabled).to be(false)
      expect(flow).to be_shadow
    end

    it 'hands the técnico option to the bot with the ia_atendendo label' do
      option = seed.parsed.step('root').option_by_id('tecnico')
      expect(option.next.status).to eq('pending')
      expect(option.next.labels).to include('ia_atendendo')
    end

    it 'is idempotent and does not bump the version on reseed' do
      first = seed
      expect { described_class.new(account: account, inbox: inbox).perform }.not_to change(TriageFlow, :count)
      expect(first.reload.version).to eq(1)
    end

    # A reseed must never take a live flow down, nor promote a shadow flow.
    it 'leaves mode and enabled untouched on reseed' do
      flow = seed
      flow.update!(enabled: true, mode: :live)
      described_class.new(account: account, inbox: inbox).perform
      expect(flow.reload).to be_live
      expect(flow.enabled).to be(true)
    end
  end
end
