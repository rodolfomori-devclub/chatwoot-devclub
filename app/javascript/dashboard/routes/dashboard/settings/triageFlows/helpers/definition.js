/**
 * Frontend mirror of TriageFlows::DefinitionValidator (app/validators).
 *
 * The builder has to refuse a definition the API would reject anyway, and it
 * has to show WhatsApp's title caps while the team types: Meta rejects an
 * over-long title at send time and the message silently ends up `failed`, so
 * the customer sees nothing. Every rule here exists in the Ruby validator —
 * when one changes, both have to change.
 */

export const ID_FORMAT = /^[a-z0-9_]{1,40}$/;
export const MAX_ID_LENGTH = 40;
export const STATUSES = ['open', 'pending', 'resolved'];
export const DEFAULT_MAX_ATTEMPTS = 3;

// [max options, max title length] per channel. Channels absent from the map
// cannot render input_select and fall back to a numbered text list.
export const CHANNEL_LIMITS = {
  'Channel::Whatsapp': { buttons: [3, 20], list: [10, 24] },
  'Channel::WebWidget': { list: [10, 60] },
  'Channel::Api': { list: [10, 60] },
};

const MESSAGES = {
  noSteps: 'must contain at least one step',
  entryStepMissing: 'must define an entry step',
  entryStepUnknown: id => `entry step '${id}' does not exist`,
  duplicateStepIds: 'contains duplicate step ids',
  invalidStepId: id =>
    `step id '${id}' must be lowercase letters, numbers or underscore (max 40)`,
  promptMissing: id => `step '${id}' needs a message`,
  noOptions: id => `step '${id}' needs at least one option`,
  duplicateOptionIds: id => `step '${id}' has duplicate option ids`,
  duplicateOptionTitles: id => `step '${id}' has options with the same title`,
  invalidOptionId: id =>
    `option id '${id}' must be lowercase letters, numbers or underscore (max 40)`,
  optionTitleMissing: id => `every option in step '${id}' needs a title`,
  transitionMissing: id => `every option in step '${id}' needs a destination`,
  selfReference: id => `step '${id}' cannot point to itself`,
  unknownStepRef: id => `option points to unknown step '${id}'`,
  invalidStatus: status =>
    `'${status}' is not a valid status (open, pending or resolved)`,
  maxAttemptsRange: 'no-match attempts must be between 1 and 5',
  noMatchActionMissing: 'no-match needs a destination',
  timeoutRequiredWhenLive: 'a live flow needs a timeout',
  timeoutRange: 'timeout must be between 1 and 1440 minutes',
  timeoutActionMissing: 'timeout needs a destination',
  tooManyOptions: (id, max) =>
    `step '${id}' has more options than this channel supports (max ${max})`,
  optionTitleTooLong: (id, max) =>
    `option titles in step '${id}' must be at most ${max} characters for this channel`,
  promptTooLong: (id, max) =>
    `step '${id}': the message plus the no-match reply must be at most ${max} characters for this channel`,
};

// Meta rejects an interactive message whose body runs past this, and the row
// just goes `failed` — the contact sees nothing at all. The re-prompt prepends
// the no-match reply to the same body, so that sum is what has to fit.
export const CHANNEL_BODY_LIMIT = { 'Channel::Whatsapp': 1024 };

// Ruby normalises titles with I18n.transliterate, which approximates Latin
// letters Unicode decomposition leaves alone: "Straße" becomes "Strasse"
// there but only "Straße" under NFD, so the API would call two titles
// duplicates that the builder happily accepted. Anything unmapped is left in
// place and dropped by the [^a-z0-9] pass, exactly as Ruby's "?" replacement is.
const APPROXIMATIONS = {
  Æ: 'AE',
  Ð: 'D',
  Ø: 'O',
  Þ: 'Th',
  ß: 'ss',
  æ: 'ae',
  ð: 'd',
  ø: 'o',
  þ: 'th',
  Đ: 'D',
  đ: 'd',
  Ħ: 'H',
  ħ: 'h',
  ı: 'i',
  Ĳ: 'IJ',
  ĳ: 'ij',
  ĸ: 'k',
  Ŀ: 'L',
  ŀ: 'l',
  Ł: 'L',
  ł: 'l',
  Ŋ: 'NG',
  ŋ: 'ng',
  Œ: 'OE',
  œ: 'oe',
  ſ: 's',
  ƒ: 'f',
};

const transliterate = value =>
  String(value ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    // eslint-disable-next-line no-control-regex
    .replace(/[^\u0000-\u007f]/g, char => APPROXIMATIONS[char] ?? char);

const isBlank = value => String(value ?? '').trim() === '';

const isPresentObject = value =>
  !!value && typeof value === 'object' && Object.keys(value).length > 0;

/**
 * Mirror of TriageFlows::OptionMatcher.normalize — two option titles that
 * normalise to the same string are treated as duplicates because a customer
 * reply would match both.
 */
export const normalizeTitle = value =>
  transliterate(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();

/**
 * Ruby's String#length counts codepoints, so an emoji is one character there
 * and two in a naive `.length`. Count the same way or the preview disagrees
 * with the error the API returns.
 */
export const titleLength = value => Array.from(String(value ?? '')).length;

// Deterministic id for input that slugifies to nothing (emoji, punctuation).
const fallbackId = value => {
  let hash = 0;
  for (let index = 0; index < value.length; index += 1) {
    hash = (hash * 31 + value.charCodeAt(index)) % 0xffffffff;
  }
  return `id_${hash.toString(36)}`;
};

export function slugify(title) {
  const source = String(title ?? '');
  const slug = transliterate(source)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, MAX_ID_LENGTH)
    .replace(/_+$/, '');

  return ID_FORMAT.test(slug) ? slug : fallbackId(source);
}

const withSuffix = (base, suffix) => {
  const tail = `_${suffix}`;
  return `${base.slice(0, MAX_ID_LENGTH - tail.length)}${tail}`;
};

export function uniqueId(base, takenIds = []) {
  const taken = new Set(takenIds);
  if (!taken.has(base)) return base;

  let suffix = 2;
  while (taken.has(withSuffix(base, suffix))) suffix += 1;
  return withSuffix(base, suffix);
}

export const emptyOption = () => ({ id: '', title: '', next: null });

export const emptyStep = () => ({
  id: '',
  prompt: '',
  options: [emptyOption()],
});

/**
 * The most options this channel can ever render, whatever shape it uses to do
 * it. WhatsApp switches from buttons to a list at four, so the button cap of
 * three is a rendering detail, not a ceiling.
 */
export function maxOptionsFor(channelType) {
  const limits = CHANNEL_LIMITS[channelType];
  if (!limits) return Infinity;

  return (limits.list || limits.buttons)[0];
}

/**
 * Which cap applies to a step, given how many options it has. WhatsApp renders
 * up to 3 options as reply buttons (tighter title cap) and more as a list.
 */
export function limitsFor(channelType, optionCount = 0) {
  const limits = CHANNEL_LIMITS[channelType];
  if (!limits) {
    return {
      maxOptions: Infinity,
      maxTitle: Infinity,
      renderMode: 'text',
    };
  }

  if (limits.buttons && optionCount <= limits.buttons[0]) {
    const [maxOptions, maxTitle] = limits.buttons;
    return { maxOptions, maxTitle, renderMode: 'buttons' };
  }

  const [maxOptions, maxTitle] = limits.list || limits.buttons;
  return { maxOptions, maxTitle, renderMode: limits.list ? 'list' : 'buttons' };
}

// Mirror of Definition#build_next: anything that is not a step or route node
// is no destination at all.
const buildNext = node => {
  if (!isPresentObject(node)) return null;
  return node.type === 'step' || node.type === 'route' ? node : null;
};

const findStep = (steps, id) => steps.find(step => step.id === id);

const optionsOf = step => (Array.isArray(step.options) ? step.options : []);

function validateRoute(route, path, errors) {
  if (!STATUSES.includes(route.status)) {
    errors.push({
      path: `${path}.status`,
      message: MESSAGES.invalidStatus(String(route.status ?? '')),
    });
  }
  // The team must belong to the account; only the API can check that, and it
  // reports a stale team as a warning on the loaded flow.
}

function validateTransition(step, option, steps, errors, key) {
  const path = `steps.${step.id}.options.${key}.next`;
  const next = buildNext(option.next);

  if (!next) {
    errors.push({ path, message: MESSAGES.transitionMissing(step.id) });
    return;
  }

  if (next.type === 'route') {
    validateRoute(next, path, errors);
    return;
  }

  if (next.step_id === step.id) {
    errors.push({ path, message: MESSAGES.selfReference(step.id) });
    return;
  }

  if (!findStep(steps, next.step_id)) {
    errors.push({
      path,
      message: MESSAGES.unknownStepRef(String(next.step_id ?? '')),
    });
  }
}

// An option's id is derived from its title on blur and filled in for anything
// still unnamed at submit time, so an empty id is app state, not a mistake the
// team can act on: it is never reported. Its position keys the messages
// instead, so two unnamed options do not read each other's errors.
function validateOption(step, option, steps, errors, index) {
  const key = option.id || String(index);

  if (option.id && !ID_FORMAT.test(String(option.id))) {
    errors.push({
      path: `steps.${step.id}.options.${key}.id`,
      message: MESSAGES.invalidOptionId(String(option.id)),
    });
  }

  if (isBlank(option.title)) {
    errors.push({
      path: `steps.${step.id}.options.${key}.title`,
      message: MESSAGES.optionTitleMissing(step.id),
    });
  }

  validateTransition(step, option, steps, errors, key);
}

// Unnamed rows are skipped on both counts: an option gets its id from its
// title on blur and a unique one at submit time, so two blank rows are the
// team mid-layout, not two options that collide. "Needs a title" is the one
// thing they can act on and it is already reported.
function validateOptionUniqueness(step, errors) {
  const options = optionsOf(step);
  const ids = options.map(option => option.id).filter(Boolean);
  if (new Set(ids).size !== ids.length) {
    errors.push({
      path: `steps.${step.id}.options`,
      message: MESSAGES.duplicateOptionIds(step.id),
    });
  }

  const titles = options
    .map(option => normalizeTitle(option.title))
    .filter(Boolean);
  if (new Set(titles).size !== titles.length) {
    errors.push({
      path: `steps.${step.id}.options`,
      message: MESSAGES.duplicateOptionTitles(step.id),
    });
  }
}

function validateChannelLimits(step, channelType, errors) {
  if (!CHANNEL_LIMITS[channelType]) return;

  const options = optionsOf(step);
  const { maxOptions, maxTitle } = limitsFor(channelType, options.length);

  if (options.length > maxOptions) {
    errors.push({
      path: `steps.${step.id}.options`,
      message: MESSAGES.tooManyOptions(step.id, maxOptions),
    });
    return;
  }

  if (options.some(option => titleLength(option.title) > maxTitle)) {
    errors.push({
      path: `steps.${step.id}.options`,
      message: MESSAGES.optionTitleTooLong(step.id, maxTitle),
    });
  }
}

function validateBodyLength(step, definition, channelType, errors) {
  const limit = CHANNEL_BODY_LIMIT[channelType];
  if (!limit) return;

  const noMatchMessage = definition.no_match?.message;
  const body = [noMatchMessage, step.prompt].filter(part => !isBlank(part));
  if (body.join('\n\n').length > limit) {
    errors.push({
      path: `steps.${step.id}.prompt`,
      message: MESSAGES.promptTooLong(step.id, limit),
    });
  }
}

function validateStep(step, steps, channelType, errors, definition) {
  if (!ID_FORMAT.test(String(step.id ?? ''))) {
    errors.push({
      path: `steps.${step.id}.id`,
      message: MESSAGES.invalidStepId(String(step.id ?? '')),
    });
  }

  if (isBlank(step.prompt)) {
    errors.push({
      path: `steps.${step.id}.prompt`,
      message: MESSAGES.promptMissing(step.id),
    });
  }

  validateBodyLength(step, definition, channelType, errors);

  const options = optionsOf(step);
  if (!options.length) {
    errors.push({
      path: `steps.${step.id}.options`,
      message: MESSAGES.noOptions(step.id),
    });
    return;
  }

  validateOptionUniqueness(step, errors);
  validateChannelLimits(step, channelType, errors);
  options.forEach((option, index) =>
    validateOption(step, option, steps, errors, index)
  );
}

function validateEntryStep(definition, steps, errors) {
  if (isBlank(definition.entry_step_id)) {
    errors.push({ path: 'entry_step_id', message: MESSAGES.entryStepMissing });
    return;
  }

  if (!findStep(steps, definition.entry_step_id)) {
    errors.push({
      path: 'entry_step_id',
      message: MESSAGES.entryStepUnknown(definition.entry_step_id),
    });
  }
}

function validateNoMatch(definition, errors) {
  const noMatch = definition.no_match || {};
  const raw = noMatch.max_attempts ?? DEFAULT_MAX_ATTEMPTS;
  const maxAttempts = Math.trunc(Number(raw));

  if (!(maxAttempts >= 1 && maxAttempts <= 5)) {
    errors.push({
      path: 'no_match.max_attempts',
      message: MESSAGES.maxAttemptsRange,
    });
  }

  const action = buildNext(noMatch.then);
  if (action?.type !== 'route') {
    errors.push({
      path: 'no_match.then',
      message: MESSAGES.noMatchActionMissing,
    });
    return;
  }

  validateRoute(action, 'no_match.then', errors);
}

function validateTimeout(definition, mode, errors) {
  const timeout = definition.timeout;

  // A live flow with no timeout can strand a customer forever; a shadow flow
  // never sends anything, so it is allowed to be incomplete.
  if (!isPresentObject(timeout)) {
    if (mode === 'live') {
      errors.push({
        path: 'timeout',
        message: MESSAGES.timeoutRequiredWhenLive,
      });
    }
    return;
  }

  const minutes = Math.trunc(Number(timeout.minutes ?? 0));
  if (!(minutes >= 1 && minutes <= 1440)) {
    errors.push({ path: 'timeout.minutes', message: MESSAGES.timeoutRange });
  }

  const action = buildNext(timeout.then);
  if (action?.type !== 'route') {
    errors.push({
      path: 'timeout.then',
      message: MESSAGES.timeoutActionMissing,
    });
    return;
  }

  validateRoute(action, 'timeout.then', errors);
}

// Steps nothing links to. Not an error: a half-built flow still has to save.
export function unreachableStepIds(definition) {
  const steps = Array.isArray(definition?.steps) ? definition.steps : [];
  const seen = new Set();
  const queue = definition?.entry_step_id ? [definition.entry_step_id] : [];

  while (queue.length) {
    const id = queue.shift();
    if (!seen.has(id)) {
      seen.add(id);
      optionsOf(findStep(steps, id) || {})
        .map(option => option.next)
        .filter(next => buildNext(next)?.type === 'step')
        .forEach(next => queue.push(next.step_id));
    }
  }

  return steps.map(step => step.id).filter(id => !seen.has(id));
}

export function validateDefinition(definition, channelType, { mode } = {}) {
  const source = definition || {};
  const steps = Array.isArray(source.steps) ? source.steps : [];
  if (!steps.length) {
    return {
      errors: [{ path: 'definition', message: MESSAGES.noSteps }],
      warnings: [],
    };
  }

  const errors = [];
  validateEntryStep(source, steps, errors);

  const ids = steps.map(step => step.id);
  if (new Set(ids).size !== ids.length) {
    errors.push({ path: 'steps', message: MESSAGES.duplicateStepIds });
  }
  steps.forEach(step => validateStep(step, steps, channelType, errors, source));

  validateNoMatch(source, errors);
  validateTimeout(source, mode, errors);

  const warnings = unreachableStepIds(source).map(stepId => ({
    type: 'unreachable_step',
    stepId,
  }));

  return { errors, warnings };
}
