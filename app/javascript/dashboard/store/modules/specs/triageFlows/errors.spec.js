import axios from 'axios';
import { createStore } from 'vuex';

import triageFlows from '../../triageFlows';

global.axios = axios;
vi.mock('axios');

const rejectWith = (status, data) => {
  const error = new Error('Request failed');
  error.response = { status, data };
  return Promise.reject(error);
};

const buildStore = () =>
  createStore({ modules: { triageFlows: { ...triageFlows } } });

const flowParams = {
  name: 'DevClub Triage',
  inboxId: 7,
  enabled: false,
  mode: 'shadow',
  definition: { entry_step_id: 'root', steps: [] },
};

describe('triageFlows error surfacing', () => {
  beforeEach(() => vi.clearAllMocks());

  it('reports the validator rules a save was refused for', async () => {
    axios.post.mockImplementation(() =>
      rejectWith(422, {
        errors: {
          definition: [
            "step 'root' needs a message",
            "every option in step 'root' needs a destination",
          ],
        },
      })
    );

    await expect(
      buildStore().dispatch('triageFlows/create', flowParams)
    ).rejects.toMatchObject({
      message: "step 'root' needs a message",
      definitionErrors: [
        "step 'root' needs a message",
        "every option in step 'root' needs a destination",
      ],
    });
  });

  // A 422 names the attribute that failed, and it is not always `definition`:
  // cloning onto an inbox that already has a flow comes back on `inbox_id`.
  it('reports a rejection keyed on something other than the definition', async () => {
    axios.post.mockImplementation(() =>
      rejectWith(422, { errors: { inbox_id: ['has already been taken'] } })
    );

    await expect(
      buildStore().dispatch('triageFlows/clone', { id: 1, inboxId: 8 })
    ).rejects.toMatchObject({
      message: 'has already been taken',
      definitionErrors: [],
    });
  });

  it('reports the channel cap a clone broke', async () => {
    const message =
      "option titles in step 'root' must be at most 20 characters for this channel";
    axios.post.mockImplementation(() =>
      rejectWith(422, { errors: { definition: [message] } })
    );

    await expect(
      buildStore().dispatch('triageFlows/clone', { id: 1, inboxId: 8 })
    ).rejects.toThrow(message);
  });

  it('reports the feature being switched off', async () => {
    axios.delete.mockImplementation(() =>
      rejectWith(403, { error: 'Triage Flows is not enabled for this account' })
    );

    await expect(
      buildStore().dispatch('triageFlows/delete', 1)
    ).rejects.toThrow('Triage Flows is not enabled for this account');
  });

  it('never hands the interface the string "undefined"', async () => {
    const bodies = [
      { errors: { inbox: ['must belong to the same account'] } },
      { errors: { name: ["can't be blank"] } },
      { errors: ['a bare array of errors'] },
      { error: 'a bare error' },
      { message: 'a bare message' },
    ];

    const messages = [];
    // eslint-disable-next-line no-restricted-syntax
    for (const data of bodies) {
      axios.patch.mockImplementation(() => rejectWith(422, data));
      // eslint-disable-next-line no-await-in-loop
      await buildStore()
        .dispatch('triageFlows/update', { id: 1, name: 'x' })
        .catch(error => messages.push(error.message));
    }

    expect(messages).toEqual([
      'must belong to the same account',
      "can't be blank",
      'a bare array of errors',
      'a bare error',
      'a bare message',
    ]);
  });

  it('leaves the loading flag down after a failure', async () => {
    axios.post.mockImplementation(() =>
      rejectWith(422, { errors: { definition: ['nope'] } })
    );
    const store = buildStore();

    await store.dispatch('triageFlows/create', flowParams).catch(() => {});

    expect(store.getters['triageFlows/getUIFlags'].isCreating).toBe(false);
  });
});
