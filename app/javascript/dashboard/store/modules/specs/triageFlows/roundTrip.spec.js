import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import axios from 'axios';
import { createStore } from 'vuex';

import triageFlows from '../../triageFlows';

global.axios = axios;
vi.mock('axios');
vi.mock('../../../utils/api');

// The same flow is replayed against the real API by
// spec/controllers/api/v1/accounts/triage_flows_controller_spec.rb, which posts
// this definition and compares the persisted jsonb key for key. Together the
// two specs cover the whole path: nothing between the editor and the database
// is allowed to touch the definition.
const apiFlow = JSON.parse(
  readFileSync(
    resolve(process.cwd(), 'spec/fixtures/triage_flows/round_trip_flow.json'),
    'utf8'
  )
);
const definition = apiFlow.definition;

const buildStore = () =>
  createStore({ modules: { triageFlows: { ...triageFlows } } });

describe('triageFlows definition round trip', () => {
  beforeEach(() => vi.clearAllMocks());

  it('hands the editor the definition exactly as the API sent it', async () => {
    axios.get.mockResolvedValue({ data: { payload: [apiFlow] } });
    const store = buildStore();

    await store.dispatch('triageFlows/get');
    const flow = store.getters['triageFlows/getTriageFlowById'](992);

    expect(flow.definition).toEqual(definition);
    // Key order too: a rebuilt object would pass toEqual and still prove the
    // definition was walked and reassembled somewhere.
    expect(JSON.stringify(flow.definition)).toBe(JSON.stringify(definition));
  });

  it('camelcases the envelope and only the envelope', async () => {
    axios.get.mockResolvedValue({ data: { payload: [apiFlow] } });
    const store = buildStore();

    await store.dispatch('triageFlows/get');
    const flow = store.getters['triageFlows/getTriageFlows'][0];

    expect(flow.createdAt).toBe(apiFlow.created_at);
    expect(flow.inbox.channelType).toBe('Channel::WebWidget');
    expect(flow).not.toHaveProperty('created_at');

    expect(Object.keys(flow.definition)).toEqual([
      'entry_step_id',
      'steps',
      'no_match',
      'timeout',
    ]);
    expect(flow.definition.steps[0].options[0].next.team_id).toBe(0);
    expect(flow.definition.steps[0].options[1].next.step_id).toBe('financeiro');
    expect(flow.definition.no_match.max_attempts).toBe(3);
    expect(flow.definition.timeout.then.status).toBe('open');
  });

  it('sends the same definition back untouched on update', async () => {
    axios.get.mockResolvedValue({ data: { payload: [apiFlow] } });
    axios.patch.mockResolvedValue({ data: apiFlow });
    const store = buildStore();

    await store.dispatch('triageFlows/get');
    const flow = store.getters['triageFlows/getTriageFlowById'](992);

    await store.dispatch('triageFlows/update', {
      id: flow.id,
      name: flow.name,
      enabled: flow.enabled,
      mode: flow.mode,
      definition: flow.definition,
    });

    const [, body] = axios.patch.mock.calls[0];
    expect(JSON.stringify(body.triage_flow.definition)).toBe(
      JSON.stringify(definition)
    );
  });

  it('snake_cases the envelope on create while leaving the definition alone', async () => {
    axios.post.mockResolvedValue({ data: apiFlow });
    const store = buildStore();

    await store.dispatch('triageFlows/create', {
      name: 'DevClub Triage',
      inboxId: 4023,
      enabled: true,
      mode: 'live',
      definition,
    });

    const [, body] = axios.post.mock.calls[0];
    expect(body.triage_flow.inbox_id).toBe(4023);
    expect(body.triage_flow).not.toHaveProperty('inboxId');
    expect(JSON.stringify(body.triage_flow.definition)).toBe(
      JSON.stringify(definition)
    );
  });

  it('survives an unlimited number of load/save cycles', async () => {
    axios.get.mockResolvedValue({ data: { payload: [apiFlow] } });
    const store = buildStore();

    for (let cycle = 0; cycle < 3; cycle += 1) {
      // eslint-disable-next-line no-await-in-loop
      await store.dispatch('triageFlows/get');
      const flow = store.getters['triageFlows/getTriageFlowById'](992);
      axios.patch.mockResolvedValue({
        data: { ...apiFlow, definition: flow.definition },
      });
      // eslint-disable-next-line no-await-in-loop
      await store.dispatch('triageFlows/update', {
        id: flow.id,
        definition: flow.definition,
      });
    }

    const [, body] = axios.patch.mock.calls.at(-1);
    expect(JSON.stringify(body.triage_flow.definition)).toBe(
      JSON.stringify(definition)
    );
  });
});
