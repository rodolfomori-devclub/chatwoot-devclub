import {
  CHANNEL_LIMITS,
  ID_FORMAT,
  emptyOption,
  emptyStep,
  limitsFor,
  maxOptionsFor,
  normalizeTitle,
  slugify,
  titleLength,
  uniqueId,
  unreachableStepIds,
  validateDefinition,
} from '../definition';

const WHATSAPP = 'Channel::Whatsapp';
const WIDGET = 'Channel::WebWidget';

const route = (overrides = {}) => ({
  type: 'route',
  team_id: 1,
  labels: [],
  status: 'open',
  ...overrides,
});

const validDefinition = () => ({
  entry_step_id: 'root',
  steps: [
    {
      id: 'root',
      prompt: 'Como podemos ajudar?',
      options: [
        {
          id: 'tecnico',
          title: 'Dúvidas',
          next: route({ status: 'pending', labels: ['ia_atendendo'] }),
        },
        {
          id: 'financeiro',
          title: 'Financeiro',
          next: { type: 'step', step_id: 'financeiro' },
        },
      ],
    },
    {
      id: 'financeiro',
      prompt: 'Qual o assunto?',
      options: [{ id: 'boleto', title: 'Boleto', next: route() }],
    },
  ],
  no_match: { message: 'Não entendi.', max_attempts: 3, then: route() },
  timeout: { minutes: 30, then: route() },
});

// A one-step flow whose only variable is the option titles, so the channel
// limit assertions are not entangled with the rest of the tree.
const definitionWithTitles = titles => ({
  entry_step_id: 'root',
  steps: [
    {
      id: 'root',
      prompt: 'Escolha uma opção',
      options: titles.map((title, index) => ({
        id: `opt_${index + 1}`,
        title,
        next: route(),
      })),
    },
  ],
  no_match: { max_attempts: 3, then: route() },
  timeout: { minutes: 30, then: route() },
});

const messages = result => result.errors.map(error => error.message);

describe('#slugify', () => {
  it('transliterates accents', () => {
    expect(slugify('Dúvidas Técnicas')).toBe('duvidas_tecnicas');
    expect(slugify('Renovação')).toBe('renovacao');
  });

  it('lowercases and collapses non-alphanumerics', () => {
    expect(slugify('Segunda  Via -- Boleto')).toBe('segunda_via_boleto');
  });

  it('trims leading and trailing separators', () => {
    expect(slugify('  ...Olá!  ')).toBe('ola');
  });

  it('trims to 40 characters', () => {
    const slug = slugify('a'.repeat(45));
    expect(slug).toHaveLength(40);
    expect(slug).toMatch(ID_FORMAT);
  });

  it('never leaves a trailing underscore after trimming', () => {
    const slug = slugify(`${'x'.repeat(39)} y`);
    expect(slug).toBe('x'.repeat(39));
    expect(slug).toMatch(ID_FORMAT);
  });

  it('falls back to a generated id for emoji-only input', () => {
    expect(slugify('🔥🔥')).toMatch(ID_FORMAT);
  });

  it('falls back to a generated id for punctuation-only input', () => {
    expect(slugify('!!! ???')).toMatch(ID_FORMAT);
  });

  it('falls back to a generated id for empty input', () => {
    expect(slugify('')).toMatch(ID_FORMAT);
    expect(slugify(null)).toMatch(ID_FORMAT);
    expect(slugify(undefined)).toMatch(ID_FORMAT);
  });

  it('generates the same fallback id for the same input', () => {
    expect(slugify('🔥')).toBe(slugify('🔥'));
    expect(slugify('🔥')).not.toBe(slugify('🎉'));
  });
});

describe('#uniqueId', () => {
  it('returns the base when it is free', () => {
    expect(uniqueId('financeiro', ['tecnico'])).toBe('financeiro');
  });

  it('appends an incrementing suffix on collision', () => {
    expect(uniqueId('financeiro', ['financeiro'])).toBe('financeiro_2');
    expect(uniqueId('financeiro', ['financeiro', 'financeiro_2'])).toBe(
      'financeiro_3'
    );
  });

  it('keeps the suffixed id within 40 characters', () => {
    const base = 'a'.repeat(40);
    const result = uniqueId(base, [base]);
    expect(result).toHaveLength(40);
    expect(result).toMatch(ID_FORMAT);
    expect(result.endsWith('_2')).toBe(true);
  });

  it('treats an empty taken list as no collision', () => {
    expect(uniqueId('root')).toBe('root');
  });
});

describe('#normalizeTitle', () => {
  it('mirrors the Ruby OptionMatcher normalisation', () => {
    expect(normalizeTitle('Dúvidas Técnicas')).toBe('duvidas tecnicas');
    expect(normalizeTitle('  Financeiro!  ')).toBe('financeiro');
    expect(normalizeTitle('Segunda-via / boleto')).toBe('segunda via boleto');
  });
});

describe('#titleLength', () => {
  it('counts codepoints so emoji match Ruby String#length', () => {
    expect(titleLength('😀')).toBe(1);
    expect(titleLength('Boleto')).toBe(6);
    expect(titleLength(null)).toBe(0);
  });
});

describe('#limitsFor', () => {
  it('renders WhatsApp as buttons up to 3 options', () => {
    expect(limitsFor(WHATSAPP, 3)).toStrictEqual({
      maxOptions: 3,
      maxTitle: 20,
      renderMode: 'buttons',
    });
  });

  it('renders WhatsApp as a list from 4 options', () => {
    expect(limitsFor(WHATSAPP, 4)).toStrictEqual({
      maxOptions: 10,
      maxTitle: 24,
      renderMode: 'list',
    });
  });

  it('treats an empty WhatsApp step as buttons', () => {
    expect(limitsFor(WHATSAPP, 0).renderMode).toBe('buttons');
  });

  it('renders the widget and the API channel as a list of 10 x 60', () => {
    expect(limitsFor(WIDGET, 3)).toStrictEqual({
      maxOptions: 10,
      maxTitle: 60,
      renderMode: 'list',
    });
    expect(limitsFor('Channel::Api', 8)).toStrictEqual({
      maxOptions: 10,
      maxTitle: 60,
      renderMode: 'list',
    });
  });

  it('falls back to an uncapped numbered text list for other channels', () => {
    expect(limitsFor('Channel::Email', 20)).toStrictEqual({
      maxOptions: Infinity,
      maxTitle: Infinity,
      renderMode: 'text',
    });
    expect(limitsFor(undefined, 1).renderMode).toBe('text');
  });

  it('exposes the same caps as the Ruby validator', () => {
    expect(CHANNEL_LIMITS[WHATSAPP]).toStrictEqual({
      buttons: [3, 20],
      list: [10, 24],
    });
  });
});

describe('#emptyStep and #emptyOption', () => {
  it('builds a blank option', () => {
    expect(emptyOption()).toStrictEqual({ id: '', title: '', next: null });
  });

  it('builds a blank step holding one blank option', () => {
    expect(emptyStep()).toStrictEqual({
      id: '',
      prompt: '',
      options: [{ id: '', title: '', next: null }],
    });
  });
});

describe('#unreachableStepIds', () => {
  it('is empty when every step is linked', () => {
    expect(unreachableStepIds(validDefinition())).toStrictEqual([]);
  });

  it('lists steps nothing points to', () => {
    const definition = validDefinition();
    definition.steps.push({
      id: 'orfao',
      prompt: 'Ninguém chega aqui',
      options: [{ id: 'volta', title: 'Voltar', next: route() }],
    });
    expect(unreachableStepIds(definition)).toStrictEqual(['orfao']);
  });
});

describe('#validateDefinition', () => {
  it('accepts the seeded shape on WhatsApp', () => {
    expect(validateDefinition(validDefinition(), WHATSAPP)).toStrictEqual({
      errors: [],
      warnings: [],
    });
  });

  it('rejects a definition with no steps', () => {
    expect(validateDefinition({ steps: [] }, WHATSAPP)).toStrictEqual({
      errors: [
        { path: 'definition', message: 'must contain at least one step' },
      ],
      warnings: [],
    });
    expect(validateDefinition(undefined, WHATSAPP).errors).toHaveLength(1);
  });

  it('requires an entry step', () => {
    const definition = validDefinition();
    definition.entry_step_id = '';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      'must define an entry step'
    );
  });

  it('rejects an entry step that does not exist', () => {
    const definition = validDefinition();
    definition.entry_step_id = 'inicio';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "entry step 'inicio' does not exist"
    );
  });

  it('rejects duplicate step ids', () => {
    const definition = validDefinition();
    definition.steps[1].id = 'root';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      'contains duplicate step ids'
    );
  });

  it('rejects a step id outside the id format', () => {
    const definition = validDefinition();
    definition.steps[1].id = 'Financeiro Geral';
    definition.steps[0].options[1].next.step_id = 'Financeiro Geral';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "step id 'Financeiro Geral' must be lowercase letters, numbers or underscore (max 40)"
    );
  });

  it('requires a prompt on every step', () => {
    const definition = validDefinition();
    definition.steps[1].prompt = '   ';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "step 'financeiro' needs a message"
    );
  });

  it('requires at least one option on every step', () => {
    const definition = validDefinition();
    definition.steps[1].options = [];
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "step 'financeiro' needs at least one option"
    );
  });

  it('rejects duplicate option ids', () => {
    const definition = validDefinition();
    definition.steps[0].options[1].id = 'tecnico';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "step 'root' has duplicate option ids"
    );
  });

  it('rejects option titles that normalise to the same string', () => {
    const definition = validDefinition();
    definition.steps[0].options[0].title = 'Financeiro';
    definition.steps[0].options[1].title = 'financeiro!';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "step 'root' has options with the same title"
    );
  });

  it('rejects an option id outside the id format', () => {
    const definition = validDefinition();
    definition.steps[0].options[0].id = 'Técnico';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "option id 'Técnico' must be lowercase letters, numbers or underscore (max 40)"
    );
  });

  it('requires a title on every option', () => {
    const definition = validDefinition();
    definition.steps[0].options[0].title = '';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "every option in step 'root' needs a title"
    );
  });

  it('requires a destination on every option', () => {
    const definition = validDefinition();
    definition.steps[0].options[0].next = null;
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "every option in step 'root' needs a destination"
    );
  });

  it('treats an unrecognised transition type as no destination', () => {
    const definition = validDefinition();
    definition.steps[0].options[0].next = { type: 'webhook' };
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "every option in step 'root' needs a destination"
    );
  });

  it('rejects a step pointing at itself', () => {
    const definition = validDefinition();
    definition.steps[0].options[1].next = { type: 'step', step_id: 'root' };
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "step 'root' cannot point to itself"
    );
  });

  it('rejects a reference to an unknown step', () => {
    const definition = validDefinition();
    definition.steps[0].options[1].next = { type: 'step', step_id: 'cobranca' };
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "option points to unknown step 'cobranca'"
    );
  });

  it('rejects a route with an unsupported status', () => {
    const definition = validDefinition();
    definition.steps[0].options[0].next.status = 'snoozed';
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      "'snoozed' is not a valid status (open, pending or resolved)"
    );
  });

  it('accepts open, pending and resolved', () => {
    ['open', 'pending', 'resolved'].forEach(status => {
      const definition = validDefinition();
      definition.steps[0].options[0].next.status = status;
      expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([]);
    });
  });

  it('leaves the team check to the API', () => {
    const definition = validDefinition();
    definition.steps[0].options[0].next.team_id = 987654;
    expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([]);
  });

  it('accepts a route with no team', () => {
    const definition = validDefinition();
    delete definition.steps[0].options[0].next.team_id;
    expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([]);
  });

  it('keeps no-match attempts between 1 and 5', () => {
    [0, 6, 'abc'].forEach(maxAttempts => {
      const definition = validDefinition();
      definition.no_match.max_attempts = maxAttempts;
      expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
        'no-match attempts must be between 1 and 5'
      );
    });

    [1, 5].forEach(maxAttempts => {
      const definition = validDefinition();
      definition.no_match.max_attempts = maxAttempts;
      expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([]);
    });
  });

  it('defaults no-match attempts to 3 when absent', () => {
    const definition = validDefinition();
    delete definition.no_match.max_attempts;
    expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([]);
  });

  it('requires a no-match destination', () => {
    const definition = validDefinition();
    definition.no_match.then = null;
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      'no-match needs a destination'
    );
  });

  it('requires the no-match destination to be a route, not a step', () => {
    const definition = validDefinition();
    definition.no_match.then = { type: 'step', step_id: 'financeiro' };
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      'no-match needs a destination'
    );
  });

  it('keeps the timeout between 1 and 1440 minutes', () => {
    [0, 1441].forEach(minutes => {
      const definition = validDefinition();
      definition.timeout.minutes = minutes;
      expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
        'timeout must be between 1 and 1440 minutes'
      );
    });

    [1, 1440].forEach(minutes => {
      const definition = validDefinition();
      definition.timeout.minutes = minutes;
      expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([]);
    });
  });

  it('requires a timeout destination', () => {
    const definition = validDefinition();
    definition.timeout.then = null;
    expect(messages(validateDefinition(definition, WHATSAPP))).toContain(
      'timeout needs a destination'
    );
  });

  it('allows a shadow flow with no timeout', () => {
    const definition = validDefinition();
    delete definition.timeout;
    expect(
      validateDefinition(definition, WHATSAPP, { mode: 'shadow' }).errors
    ).toStrictEqual([]);
  });

  it('requires a timeout once the flow is live', () => {
    const definition = validDefinition();
    delete definition.timeout;
    expect(
      messages(validateDefinition(definition, WHATSAPP, { mode: 'live' }))
    ).toContain('a live flow needs a timeout');
  });

  it('treats an empty timeout object as no timeout', () => {
    const definition = validDefinition();
    definition.timeout = {};
    expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([]);
    expect(
      messages(validateDefinition(definition, WHATSAPP, { mode: 'live' }))
    ).toContain('a live flow needs a timeout');
  });

  it('accepts a 20 character title on a 3 option WhatsApp step', () => {
    const definition = definitionWithTitles([
      'x'.repeat(20),
      'Boleto',
      'Outro',
    ]);
    expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([]);
  });

  it('rejects a 21 character title on a 3 option WhatsApp step', () => {
    const definition = definitionWithTitles([
      'x'.repeat(21),
      'Boleto',
      'Outro',
    ]);
    expect(messages(validateDefinition(definition, WHATSAPP))).toStrictEqual([
      "option titles in step 'root' must be at most 20 characters for this channel",
    ]);
  });

  it('accepts the very same definition on a widget inbox', () => {
    const definition = definitionWithTitles([
      'x'.repeat(21),
      'Boleto',
      'Outro',
    ]);
    expect(validateDefinition(definition, WIDGET).errors).toStrictEqual([]);
  });

  it('raises the WhatsApp cap to 24 once the step spills into a list', () => {
    const short = ['Boleto', 'Nota', 'Outro'];
    expect(
      validateDefinition(
        definitionWithTitles(['x'.repeat(24), ...short]),
        WHATSAPP
      ).errors
    ).toStrictEqual([]);
    expect(
      messages(
        validateDefinition(
          definitionWithTitles(['x'.repeat(25), ...short]),
          WHATSAPP
        )
      )
    ).toStrictEqual([
      "option titles in step 'root' must be at most 24 characters for this channel",
    ]);
  });

  it('counts an emoji title as one character, like the Ruby validator', () => {
    expect(
      validateDefinition(
        definitionWithTitles(['😀'.repeat(20), 'b', 'c']),
        WHATSAPP
      ).errors
    ).toStrictEqual([]);
    expect(
      messages(
        validateDefinition(
          definitionWithTitles(['😀'.repeat(21), 'b', 'c']),
          WHATSAPP
        )
      )
    ).toStrictEqual([
      "option titles in step 'root' must be at most 20 characters for this channel",
    ]);
  });

  it('rejects more options than the channel can render', () => {
    const titles = Array.from(
      { length: 11 },
      (_, index) => `Opcao ${index + 1}`
    );
    expect(
      messages(validateDefinition(definitionWithTitles(titles), WHATSAPP))
    ).toStrictEqual([
      "step 'root' has more options than this channel supports (max 10)",
    ]);
    expect(
      messages(validateDefinition(definitionWithTitles(titles), WIDGET))
    ).toStrictEqual([
      "step 'root' has more options than this channel supports (max 10)",
    ]);
  });

  it('applies no channel limits to a channel without input_select', () => {
    const titles = Array.from(
      { length: 12 },
      (_, index) => `Opcao muito longa numero ${index + 1}`
    );
    expect(
      validateDefinition(definitionWithTitles(titles), 'Channel::Email').errors
    ).toStrictEqual([]);
  });

  it('reports an unreachable step as a warning, not an error', () => {
    const definition = validDefinition();
    definition.steps.push({
      id: 'orfao',
      prompt: 'Ninguém chega aqui',
      options: [{ id: 'volta', title: 'Voltar', next: route() }],
    });

    expect(validateDefinition(definition, WHATSAPP)).toStrictEqual({
      errors: [],
      warnings: [{ type: 'unreachable_step', stepId: 'orfao' }],
    });
  });

  // The Add button reads this, not the count-dependent cap: WhatsApp shows
  // three options as buttons and up to ten as a list, so three is a rendering
  // detail rather than a ceiling.
  describe('maxOptionsFor', () => {
    it('reports what the channel can render at all', () => {
      expect(maxOptionsFor(WHATSAPP)).toBe(10);
      expect(maxOptionsFor('Channel::WebWidget')).toBe(10);
      expect(maxOptionsFor('Channel::Sms')).toBe(Infinity);
    });
  });

  // The body of a WhatsApp interactive message caps at 1024 and Meta rejects
  // the whole thing over it, which lands as a `failed` row the contact never
  // sees.
  it('rejects a prompt that cannot fit in a WhatsApp body with the no-match reply', () => {
    const definition = validDefinition();
    definition.steps[0].prompt = 'a'.repeat(1020);
    definition.no_match.message = 'b'.repeat(10);

    expect(validateDefinition(definition, WHATSAPP).errors).toContainEqual({
      path: 'steps.root.prompt',
      message:
        "step 'root': the message plus the no-match reply must be at most 1024 characters for this channel",
    });
  });

  it('leaves a channel with no body cap alone', () => {
    const definition = validDefinition();
    definition.steps[0].prompt = 'a'.repeat(4000);

    expect(validateDefinition(definition, 'Channel::WebWidget').errors).toEqual(
      []
    );
  });

  // Two unnamed options used to share the bucket keyed by their empty id and
  // each rendered the other's messages.
  it('keys an unnamed option error by its position, not by its empty id', () => {
    const definition = validDefinition();
    definition.steps[0].options = [
      { id: '', title: '', next: route() },
      { id: '', title: '', next: route() },
    ];

    const paths = validateDefinition(definition, WHATSAPP).errors.map(
      error => error.path
    );

    expect(paths).toEqual([
      'steps.root.options.0.title',
      'steps.root.options.1.title',
    ]);
  });

  it('anchors each error to the field that caused it', () => {
    const definition = validDefinition();
    definition.steps[0].options[0].title = '';
    definition.steps[1].prompt = '';

    expect(validateDefinition(definition, WHATSAPP).errors).toStrictEqual([
      {
        path: 'steps.root.options.tecnico.title',
        message: "every option in step 'root' needs a title",
      },
      {
        path: 'steps.financeiro.prompt',
        message: "step 'financeiro' needs a message",
      },
    ]);
  });
});
