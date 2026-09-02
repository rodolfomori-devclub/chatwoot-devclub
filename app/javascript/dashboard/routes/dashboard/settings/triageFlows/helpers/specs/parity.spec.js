import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { validateDefinition, unreachableStepIds } from '../definition';

// Both validators are driven from one fixture. spec/validators/triage_flows/
// definition_validator_parity_spec.rb asserts the Ruby validator produces the
// same message list for the same case, so a rule that drifts on either side
// fails here or there. The backend is the source of truth: a mismatch means
// this mirror is wrong.
const cases = JSON.parse(
  readFileSync(
    resolve(process.cwd(), 'spec/fixtures/triage_flows/validator_parity.json'),
    'utf8'
  )
);

describe('validateDefinition parity with TriageFlows::DefinitionValidator', () => {
  // The one deliberate divergence: an option that has not been named yet. Its
  // id is derived from its title on blur and a unique one is filled in at
  // submit time, so a blank id — and two blank rows "colliding" — is app state
  // rather than something the team can act on. The API still rejects a blank
  // id; normalizeDefinition is what guarantees it never receives one from this
  // screen.
  it('says nothing about an unnamed option beyond the title it needs', () => {
    const definition = {
      entry_step_id: 'root',
      steps: [
        {
          id: 'root',
          prompt: 'Como podemos ajudar?',
          options: [
            {
              id: '',
              title: '',
              next: {
                type: 'route',
                team_id: null,
                labels: [],
                status: 'open',
              },
            },
            {
              id: '',
              title: '',
              next: {
                type: 'route',
                team_id: null,
                labels: [],
                status: 'open',
              },
            },
          ],
        },
      ],
      no_match: {
        message: 'Não entendi.',
        max_attempts: 3,
        then: { type: 'route', team_id: null, labels: [], status: 'open' },
      },
      timeout: {
        minutes: 30,
        then: { type: 'route', team_id: null, labels: [], status: 'open' },
      },
    };

    expect(validateDefinition(definition, 'Channel::Whatsapp').errors).toEqual([
      {
        path: 'steps.root.options.0.title',
        message: "every option in step 'root' needs a title",
      },
      {
        path: 'steps.root.options.1.title',
        message: "every option in step 'root' needs a title",
      },
    ]);
  });

  it('exercises both channels, both modes and more than ten definitions', () => {
    expect(cases.length).toBeGreaterThanOrEqual(10);
    expect([...new Set(cases.map(c => c.channel_type))].sort()).toEqual([
      'Channel::WebWidget',
      'Channel::Whatsapp',
    ]);
    expect([...new Set(cases.map(c => c.mode))].sort()).toEqual([
      'live',
      'shadow',
    ]);
  });

  it.each(cases.map(c => [c.name, c]))('agrees on %s', (_name, kase) => {
    const { errors } = validateDefinition(kase.definition, kase.channel_type, {
      mode: kase.mode,
    });

    expect(errors.map(error => error.message).sort()).toEqual(
      [...kase.expected_errors].sort()
    );
  });

  it.each(cases.map(c => [c.name, c]))(
    'reports the same unreachable steps for %s',
    (_name, kase) => {
      expect(unreachableStepIds(kase.definition).sort()).toEqual(
        [...kase.expected_unreachable].sort()
      );
    }
  );
});
