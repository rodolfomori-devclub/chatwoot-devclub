FactoryBot.define do
  factory :triage_flow do
    account
    inbox { association :inbox, account: account }
    sequence(:name) { |n| "Triage Flow #{n}" }
    enabled { false }
    mode { :shadow }

    transient do
      # Teams referenced by the default definition. Built lazily so a bare
      # `create(:triage_flow)` still validates.
      tech_team { association :team, account: account }
      general_team { association :team, account: account }
    end

    definition do
      {
        'entry_step_id' => 'root',
        'steps' => [
          { 'id' => 'root', 'prompt' => 'Como podemos ajudar?', 'options' => [
            { 'id' => 'tecnico', 'title' => 'Dúvidas Técnicas',
              'next' => { 'type' => 'route', 'team_id' => tech_team.id, 'labels' => ['ia_atendendo'], 'status' => 'pending' } },
            { 'id' => 'gerais', 'title' => 'Dúvidas Gerais',
              'next' => { 'type' => 'route', 'team_id' => general_team.id, 'labels' => [], 'status' => 'open' } },
            { 'id' => 'financeiro', 'title' => 'Financeiro', 'next' => { 'type' => 'step', 'step_id' => 'financeiro' } }
          ] },
          { 'id' => 'financeiro', 'prompt' => 'Sobre o que você precisa falar?', 'options' => [
            { 'id' => 'renovacao', 'title' => 'Renovação',
              'next' => { 'type' => 'route', 'team_id' => general_team.id, 'labels' => [], 'status' => 'open' } }
          ] }
        ],
        'no_match' => { 'message' => 'Não entendi.', 'max_attempts' => 3,
                        'then' => { 'type' => 'route', 'team_id' => general_team.id, 'labels' => [], 'status' => 'open' } },
        'timeout' => { 'minutes' => 30,
                       'then' => { 'type' => 'route', 'team_id' => general_team.id, 'labels' => [], 'status' => 'open' } }
      }
    end
  end
end
