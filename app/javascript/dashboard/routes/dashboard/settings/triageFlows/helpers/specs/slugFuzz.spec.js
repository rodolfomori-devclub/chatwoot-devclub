import {
  ID_FORMAT,
  MAX_ID_LENGTH,
  normalizeTitle,
  slugify,
  uniqueId,
} from '../definition';

// An id that does not match ID_FORMAT is rejected by the Ruby validator with
// "option id '…' must be lowercase letters, numbers or underscore", so a title
// the builder cannot slugify would make the flow unsaveable with no way for
// the team to fix it — the id field is not editable. slugify therefore has to
// answer with a legal id for literally anything a person can type.
const CORPUS = [
  '',
  ' ',
  '   \t\n  ',
  'Financeiro',
  'Dúvidas Técnicas',
  'Renovação',
  'ÀÉÎÕÜ Ç Ñ',
  'Straße',
  'Œuvre',
  'Ærø',
  'Łódź',
  '  leading and trailing  ',
  '---',
  '___',
  '...!?#$%&*()',
  '🙂',
  '🙂🙂🙂',
  '👨‍👩‍👧‍👦',
  '中文选项',
  'Опция',
  'خيار',
  'עברית',
  '42',
  '0',
  'a',
  '_',
  '_a_',
  'a'.repeat(41),
  'a'.repeat(200),
  'á'.repeat(200),
  `${'a'.repeat(39)} b`,
  `${'a'.repeat(40)} b`,
  `${'a'.repeat(45)}!!!`,
  `${'x'.repeat(39)}🙂`,
  'Opção 1 — Financeiro / Renovação (anual)',
  '​',
  'null',
  null,
  undefined,
  0,
  42,
];

const RANDOM_ALPHABET = Array.from(
  'abcXYZ019 _-.,;:!?/\\()[]{}<>@#$%&*+=|~`"\'\náàâãçéêíóôõúüñÆØßŁœ中日한🙂🎉€✓​'
);

// Deterministic pseudo-random so a failure is reproducible from its seed.
const randomTitle = seed => {
  let value = seed * 2654435761;
  let out = '';
  const length = seed % 60;
  for (let index = 0; index <= length; index += 1) {
    value = (value * 1103515245 + 12345) % 2147483648;
    out += RANDOM_ALPHABET[value % RANDOM_ALPHABET.length];
  }
  return out;
};

const FUZZ = Array.from({ length: 2000 }, (_, seed) => randomTitle(seed + 1));

describe('slugify', () => {
  it('returns an id the backend accepts for every hand-picked title', () => {
    const rejected = CORPUS.filter(value => !ID_FORMAT.test(slugify(value)));

    expect(rejected).toEqual([]);
  });

  it('returns an id the backend accepts for 2000 fuzzed titles', () => {
    const rejected = FUZZ.filter(value => {
      const slug = slugify(value);
      return !ID_FORMAT.test(slug) || slug.length > MAX_ID_LENGTH;
    });

    expect(rejected).toEqual([]);
  });

  it('is deterministic', () => {
    CORPUS.forEach(value => expect(slugify(value)).toBe(slugify(value)));
  });

  it('keeps the readable part of a normal title', () => {
    expect(slugify('Dúvidas Técnicas')).toBe('duvidas_tecnicas');
    expect(slugify('  Renovação!  ')).toBe('renovacao');
    expect(slugify('Straße')).toBe('strasse');
  });

  it('never ends on a separator after the 40 character cut', () => {
    const slug = slugify(`${'a'.repeat(40)} tail`);

    expect(slug).toBe('a'.repeat(40));
    expect(slug.endsWith('_')).toBe(false);
  });

  it('falls back to a stable synthetic id when nothing survives', () => {
    expect(slugify('🙂')).toMatch(/^id_[a-z0-9]+$/);
    expect(slugify('🙂')).toBe(slugify('🙂'));
    expect(slugify('🙂')).not.toBe(slugify('🎉'));
  });
});

describe('uniqueId', () => {
  it('disambiguates two different titles that slugify the same', () => {
    const first = slugify('Renovação');
    const second = slugify('renovacao!');

    expect(second).toBe(first);
    expect(uniqueId(second, [first])).toBe('renovacao_2');
  });

  it('keeps suffixing until it finds a free id', () => {
    expect(uniqueId('a', ['a', 'a_2', 'a_3'])).toBe('a_4');
  });

  it('stays inside the 40 character cap while suffixing', () => {
    const base = 'b'.repeat(40);
    const taken = [base];

    for (let round = 2; round < 15; round += 1) {
      const next = uniqueId(base, taken);
      expect(next).toMatch(ID_FORMAT);
      expect(next.length).toBeLessThanOrEqual(MAX_ID_LENGTH);
      taken.push(next);
    }

    expect(new Set(taken).size).toBe(taken.length);
  });

  it('leaves an id alone when nothing has claimed it', () => {
    expect(uniqueId('financeiro', ['tecnico'])).toBe('financeiro');
  });
});

describe('normalizeTitle', () => {
  it('collapses the accents and punctuation the matcher ignores', () => {
    expect(normalizeTitle('Renovação!')).toBe(normalizeTitle('renovacao'));
    expect(normalizeTitle('Straße')).toBe(normalizeTitle('Strasse'));
    expect(normalizeTitle('  Dúvidas   Técnicas ')).toBe('duvidas tecnicas');
  });

  it('reduces anything with no letters to the empty string', () => {
    expect(normalizeTitle('🙂')).toBe('');
    expect(normalizeTitle('---')).toBe('');
    expect(normalizeTitle(null)).toBe('');
  });
});
