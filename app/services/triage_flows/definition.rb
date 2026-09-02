# Read-only, parsed view over TriageFlow#definition (jsonb).
#
# Everything in the engine reads the flow through this object, so the on-disk
# JSON shape is described in exactly one place. The JSON uses "then" for the
# transition of a no_match/timeout branch; it is exposed here as `action`
# because a Struct member named :then would shadow Object#then.
class TriageFlows::Definition
  Step = Struct.new(:id, :prompt, :options, keyword_init: true) do
    def option_by_id(id)
      options.find { |o| o.id == id }
    end
  end

  Option = Struct.new(:id, :title, :next, keyword_init: true)

  # A terminal action: where the conversation lands.
  Route = Struct.new(:team_id, :labels, :status, :message, keyword_init: true)

  # A transition to another step.
  StepRef = Struct.new(:step_id, keyword_init: true)

  NoMatch = Struct.new(:message, :max_attempts, :action, keyword_init: true)
  Timeout = Struct.new(:minutes, :action, keyword_init: true)

  STATUSES = %w[open pending resolved].freeze
  DEFAULT_MAX_ATTEMPTS = 3

  attr_reader :raw

  def initialize(raw)
    @raw = as_node(raw) || {}.with_indifferent_access
  end

  def entry_step_id
    raw[:entry_step_id]
  end

  def steps
    @steps ||= Array(raw[:steps]).map { |s| build_step(s) }
  end

  def step(id)
    steps.find { |s| s.id == id }
  end

  def entry_step
    step(entry_step_id)
  end

  def no_match
    @no_match ||= begin
      nm = as_node(raw[:no_match]) || {}
      NoMatch.new(message: nm[:message],
                  max_attempts: to_number(nm[:max_attempts] || DEFAULT_MAX_ATTEMPTS),
                  action: build_next(nm[:then]))
    end
  end

  def timeout
    return @timeout if defined?(@timeout)

    t = as_node(raw[:timeout])
    @timeout = t.presence && Timeout.new(minutes: to_number(t[:minutes]), action: build_next(t[:then]))
  end

  def blank?
    steps.empty?
  end

  # Steps that cannot be reached from the entry step. Not an error — the UI
  # surfaces them so a half-built flow is still saveable.
  def unreachable_step_ids
    steps.map(&:id) - reachable_step_ids.to_a
  end

  def warnings(account = nil)
    unreachable_step_ids.map { |id| { 'type' => 'unreachable_step', 'step_id' => id } } +
      missing_team_warnings(account)
  end

  def routes
    @routes ||= (step_transitions + [no_match.action, timeout&.action]).compact.grep(Route)
  end

  private

  # A step that is not an object still counts as a step: parsed empty, it is
  # reported by the validator rather than silently dropped from the tree.
  def build_step(raw_step)
    step = as_node(raw_step) || {}
    Step.new(id: step[:id], prompt: step[:prompt],
             options: Array(step[:options]).map { |o| build_option(o) })
  end

  def build_option(raw_option)
    option = as_node(raw_option) || {}
    Option.new(id: option[:id], title: option[:title], next: build_next(option[:next]))
  end

  def step_transitions
    steps.flat_map { |s| s.options.map(&:next) }
  end

  def reachable_step_ids
    seen = Set.new
    queue = Array(entry_step_id)
    while (id = queue.shift)
      next unless seen.add?(id)

      queue.concat(next_step_ids_of(id))
    end
    seen
  end

  def next_step_ids_of(step_id)
    step(step_id)&.options.to_a.map(&:next).grep(StepRef).map(&:step_id)
  end

  def missing_team_warnings(account)
    return [] if account.blank?

    known = account.teams.pluck(:id)
    routes.filter_map { |r| team_warning_for(r, known) }.uniq
  end

  def team_warning_for(route, known_team_ids)
    return if route.team_id.blank? || known_team_ids.include?(route.team_id)

    { 'type' => 'missing_team', 'team_id' => route.team_id }
  end

  def build_next(raw_next)
    node = as_node(raw_next)
    return nil if node.blank?

    case node[:type]
    when 'step' then StepRef.new(step_id: node[:step_id])
    when 'route' then build_route(node)
    end
  end

  def build_route(node)
    team_id = node[:team_id]
    Route.new(team_id: team_id.presence && to_number(team_id), labels: Array(node[:labels]).map(&:to_s),
              status: node[:status], message: node[:message].presence)
  end

  # The definition is free-form jsonb and can be posted straight to the API, so
  # nothing guarantees a node is an object. Anything else reads as "not there"
  # and the validator turns that into a 422 instead of the parser raising.
  def as_node(value)
    value.is_a?(Hash) ? value.with_indifferent_access : nil
  end

  # Same reason, one level down: a value where a number belongs reads as 0,
  # which every range check in the validator already rejects.
  def to_number(value)
    value.respond_to?(:to_i) ? value.to_i : 0
  end
end
