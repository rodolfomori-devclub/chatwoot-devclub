# Builds the DevClub triage tree on one inbox.
#
# The tree lives in code rather than in a fixture so a cutover is one rake task
# on the production console, and so the option ids stay stable across reseeds:
# a running session stores `current_step_id`, and renaming a step under it would
# strand every customer mid-menu.
class TriageFlows::SeedService
  class MissingTeamError < StandardError; end

  FLOW_NAME = 'DevClub Triage'.freeze
  NO_MATCH_MESSAGE = 'Não entendi. Responda com o número ou o nome de uma das opções.'.freeze
  TIMEOUT_MINUTES = 30
  MAX_ATTEMPTS = 3

  # Role => accepted team names, best first. Matched without case or accents,
  # so "Renovação", "renovacao" and "RENOVACAO" all resolve to the same team.
  TEAM_NAMES = {
    tecnico: ['Suporte Técnico', 'Técnico', 'Dúvidas Técnicas'],
    geral: ['Atendimento Geral', 'Suporte Geral', 'Geral', 'Dúvidas Gerais'],
    renovacao: %w[Renovação Renovações Retenção],
    financeiro: %w[Financeiro Finanças]
  }.freeze

  pattr_initialize [:account!, :inbox!]

  def perform
    teams = resolve_teams
    flow = TriageFlow.find_or_initialize_by(inbox_id: inbox.id)
    # mode/enabled are only seeded on create: a reseed must never take a live
    # flow down, nor push a shadow flow into production behind the operator.
    flow.assign_attributes(account: account, mode: :shadow, enabled: false) if flow.new_record?
    flow.assign_attributes(name: FLOW_NAME, definition: definition(teams))
    flow.save!
    flow
  end

  private

  # Two passes, and a team can only be claimed once.
  #
  # Real DevClub teams are "suporte técnico", "suporte geral", "suporte
  # financeiro", "suporte renovação". A single greedy substring pass sent the
  # `geral` role to "suporte técnico" (both contain "suporte") and silently
  # funnelled every fallback into the wrong queue, so: exact matches are
  # resolved first and removed from the pool, then the remaining roles match on
  # whole words only.
  def resolve_teams
    pool = teams_by_name.dup
    resolved = {}
    # rubocop:disable Style/CombinableLoops -- the two passes are the fix:
    # merging them lets an early role win a team that a later role matches
    # exactly, which is how `geral` used to capture "suporte técnico".
    TEAM_NAMES.each_key { |role| claim(resolved, pool, role) { |names| exact_team(pool, names) } }
    TEAM_NAMES.each_key { |role| claim(resolved, pool, role) { |names| word_match_team(pool, names) } }
    # rubocop:enable Style/CombinableLoops

    missing = TEAM_NAMES.keys - resolved.keys
    return resolved if missing.empty?

    raise MissingTeamError,
          "account #{account.id} has no team for: #{missing.join(', ')}. " \
          "Expected one of #{missing.map { |role| TEAM_NAMES[role].join(' / ') }.join(', ')}."
  end

  def claim(resolved, pool, role)
    return if resolved.key?(role)

    team = yield(TEAM_NAMES[role])
    return if team.nil?

    resolved[role] = team
    pool.delete_if { |_name, candidate| candidate == team }
  end

  def exact_team(pool, names)
    names.filter_map { |name| pool[normalize(name)] }.first
  end

  # "Financeiro DevClub" answers to the `financeiro` role, but "suporte
  # técnico" must not answer to a role whose key is merely "suporte".
  # Deterministic: candidates are considered in a stable order.
  def word_match_team(pool, names)
    keys = names.map { |name| normalize(name) }
    pool.sort_by { |_name, team| team.id }
        .find { |name, _team| keys.any? { |key| words_include?(name, key) } }&.last
  end

  def words_include?(name, key)
    haystack = name.split
    needle = key.split
    needle.any? && needle.all? { |word| haystack.include?(word) }
  end

  def teams_by_name
    @teams_by_name ||= account.teams.index_by { |team| normalize(team.name) }
  end

  def normalize(value)
    TriageFlows::OptionMatcher.normalize(value)
  end

  def definition(teams)
    {
      'entry_step_id' => 'root',
      'steps' => [root_step(teams), financeiro_step(teams)],
      'no_match' => { 'message' => NO_MATCH_MESSAGE, 'max_attempts' => MAX_ATTEMPTS, 'then' => route(teams[:geral]) },
      'timeout' => { 'minutes' => TIMEOUT_MINUTES, 'then' => route(teams[:geral]) }
    }
  end

  def root_step(teams)
    {
      'id' => 'root',
      'prompt' => 'Olá! Sou o atendimento do DevClub. Como podemos te ajudar?',
      'options' => [
        { 'id' => 'tecnico', 'title' => 'Dúvidas Técnicas',
          'next' => route(teams[:tecnico], status: 'pending', labels: ['ia_atendendo']) },
        { 'id' => 'gerais', 'title' => 'Dúvidas Gerais', 'next' => route(teams[:geral]) },
        { 'id' => 'financeiro', 'title' => 'Financeiro', 'next' => { 'type' => 'step', 'step_id' => 'financeiro' } }
      ]
    }
  end

  def financeiro_step(teams)
    {
      'id' => 'financeiro',
      'prompt' => 'Sobre o que você precisa falar com o financeiro?',
      'options' => [
        { 'id' => 'renovacao', 'title' => 'Renovação', 'next' => route(teams[:renovacao]) },
        { 'id' => 'comprar_formacao', 'title' => 'Comprar Formação',
          'next' => route(teams[:renovacao], labels: ['comprar_formacao']) },
        { 'id' => 'outros', 'title' => 'Outros assuntos', 'next' => route(teams[:financeiro]) }
      ]
    }
  end

  def route(team, status: 'open', labels: [])
    { 'type' => 'route', 'team_id' => team.id, 'labels' => labels, 'status' => status }
  end
end
