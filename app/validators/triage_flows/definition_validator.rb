# Validates TriageFlow#definition.
#
# Channel limits are enforced here because Chatwoot does not truncate option
# titles: an over-long title is rejected by Meta and the message silently ends
# up as `failed`, so the customer sees nothing. Catching it at save time is the
# only place the team gets feedback.
class TriageFlows::DefinitionValidator < ActiveModel::Validator
  ID_FORMAT = /\A[a-z0-9_]{1,40}\z/
  MAX_ATTEMPTS_RANGE = (1..5)
  TIMEOUT_RANGE = (1..1440)

  # Meta caps an interactive message body at 1024 characters and rejects the
  # whole message over it, which lands as a `failed` row the customer never
  # sees. The re-prompt prepends the no-match reply to the same body, so that
  # sum is what has to fit.
  CHANNEL_BODY_LIMIT = { 'Channel::Whatsapp' => 1024 }.freeze

  # [max options, max title length] per channel.
  CHANNEL_LIMITS = {
    'Channel::Whatsapp' => { buttons: [3, 20], list: [10, 24] },
    'Channel::WebWidget' => { list: [10, 60] },
    'Channel::Api' => { list: [10, 60] }
  }.freeze

  def validate(record)
    @record = record
    @definition = record.parsed
    return add(:definition, :no_steps) if @definition.blank?

    validate_entry_step
    validate_steps
    validate_no_match
    validate_timeout
  end

  private

  attr_reader :record, :definition

  def add(attribute, key, **args)
    record.errors.add(attribute, I18n.t("triage_flow.errors.#{key}", **args))
  end

  def validate_entry_step
    return add(:definition, :entry_step_missing) if definition.entry_step_id.blank?

    add(:definition, :entry_step_unknown, step_id: definition.entry_step_id) if definition.entry_step.blank?
  end

  def validate_steps
    ids = definition.steps.map(&:id)
    add(:definition, :duplicate_step_ids) if ids.uniq.length != ids.length

    definition.steps.each { |step| validate_step(step) }
  end

  def validate_step(step)
    add(:definition, :invalid_step_id, step_id: step.id.to_s) unless step.id.to_s.match?(ID_FORMAT)
    add(:definition, :prompt_missing, step_id: step.id) if step.prompt.blank?
    validate_body_length(step)
    return add(:definition, :no_options, step_id: step.id) if step.options.empty?

    validate_option_uniqueness(step)
    validate_channel_limits(step)
    step.options.each { |option| validate_option(step, option) }
  end

  def validate_option_uniqueness(step)
    ids = step.options.map(&:id)
    add(:definition, :duplicate_option_ids, step_id: step.id) if ids.uniq.length != ids.length

    titles = step.options.map { |o| TriageFlows::OptionMatcher.normalize(o.title) }
    add(:definition, :duplicate_option_titles, step_id: step.id) if titles.uniq.length != titles.length
  end

  def validate_option(step, option)
    add(:definition, :invalid_option_id, option_id: option.id.to_s) unless option.id.to_s.match?(ID_FORMAT)
    add(:definition, :option_title_missing, step_id: step.id) if option.title.blank?
    validate_transition(step, option.next)
  end

  def validate_transition(step, transition)
    case transition
    when TriageFlows::Definition::StepRef then validate_step_ref(step, transition)
    when TriageFlows::Definition::Route then validate_route(transition)
    else add(:definition, :transition_missing, step_id: step.id)
    end
  end

  def validate_step_ref(step, ref)
    return add(:definition, :self_reference, step_id: step.id) if ref.step_id == step.id

    add(:definition, :unknown_step_ref, step_id: ref.step_id.to_s) if definition.step(ref.step_id).blank?
  end

  def validate_route(route)
    add(:definition, :invalid_status, status: route.status.to_s) unless TriageFlows::Definition::STATUSES.include?(route.status)
    return if route.team_id.blank? || record.account.blank?

    add(:definition, :unknown_team, team_id: route.team_id) unless record.account.teams.exists?(id: route.team_id)
  end

  def validate_no_match
    add(:definition, :max_attempts_range) unless MAX_ATTEMPTS_RANGE.cover?(definition.no_match.max_attempts)
    add(:definition, :no_match_action_missing) unless definition.no_match.action.is_a?(TriageFlows::Definition::Route)
    validate_route(definition.no_match.action) if definition.no_match.action.is_a?(TriageFlows::Definition::Route)
  end

  def validate_timeout
    timeout = definition.timeout
    # A live flow with no timeout can strand a customer forever; shadow mode
    # never sends anything, so it is allowed to be incomplete.
    return add(:definition, :timeout_required_when_live) if timeout.blank? && record.live?
    return if timeout.blank?

    add(:definition, :timeout_range) unless TIMEOUT_RANGE.cover?(timeout.minutes)
    add(:definition, :timeout_action_missing) unless timeout.action.is_a?(TriageFlows::Definition::Route)
    validate_route(timeout.action) if timeout.action.is_a?(TriageFlows::Definition::Route)
  end

  def validate_body_length(step)
    limit = CHANNEL_BODY_LIMIT[record.inbox&.channel_type]
    return if limit.blank?

    length = [definition.no_match.message, step.prompt].compact_blank.join("\n\n").length
    add(:definition, :prompt_too_long, step_id: step.id, max: limit) if length > limit
  end

  def validate_channel_limits(step)
    limits = CHANNEL_LIMITS[record.inbox&.channel_type]
    return if limits.blank?

    max_options, max_title = bounds_for(limits, step.options.length)
    return add(:definition, :too_many_options, step_id: step.id, max: max_options) if step.options.length > max_options

    return if step.options.none? { |o| o.title.to_s.length > max_title }

    add(:definition, :option_title_too_long, step_id: step.id, max: max_title)
  end

  # WhatsApp renders <=3 options as reply buttons (tighter title cap) and more
  # as a list, so the applicable cap depends on how many options the step has.
  def bounds_for(limits, option_count)
    buttons = limits[:buttons]
    return buttons if buttons && option_count <= buttons[0]

    limits[:list] || buttons
  end
end
