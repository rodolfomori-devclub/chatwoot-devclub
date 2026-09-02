import axios from 'axios';
import { actions } from '../../triageFlows';
import types from '../../../mutation-types';

const commit = vi.fn();

global.axios = axios;
vi.mock('axios');
vi.mock('../../../utils/api');

// The exact JSON the triage engine reads. Every key here is a wire contract:
// if the store re-cases any of it, the flow stops routing.
const definition = {
  entry_step_id: 'root',
  steps: [
    {
      id: 'root',
      prompt: 'Como podemos ajudar?',
      options: [
        {
          id: 'tecnico',
          title: 'Dúvidas Técnicas',
          next: {
            type: 'route',
            team_id: 1,
            labels: ['ia_atendendo'],
            status: 'pending',
          },
        },
        {
          id: 'financeiro',
          title: 'Financeiro',
          next: { type: 'step', step_id: 'financeiro' },
        },
      ],
    },
  ],
  no_match: {
    message: 'Não entendi.',
    max_attempts: 3,
    then: { type: 'route', team_id: 2, labels: [], status: 'open' },
  },
  timeout: {
    minutes: 30,
    then: { type: 'route', team_id: 2, labels: [], status: 'open' },
  },
};

const apiFlow = {
  id: 1,
  name: 'DevClub triage',
  enabled: true,
  mode: 'shadow',
  version: 4,
  definition,
  inbox: { id: 7, name: 'WhatsApp', channel_type: 'Channel::Whatsapp' },
  warnings: [{ type: 'missing_team', team_id: 9 }],
  created_at: 1704110400,
  updated_at: 1704114000,
};

const storeFlow = {
  id: 1,
  name: 'DevClub triage',
  enabled: true,
  mode: 'shadow',
  version: 4,
  definition,
  inbox: { id: 7, name: 'WhatsApp', channelType: 'Channel::Whatsapp' },
  warnings: [{ type: 'missing_team', teamId: 9 }],
  createdAt: 1704110400,
  updatedAt: 1704114000,
};

describe('#actions', () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  describe('#get', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({ data: { payload: [apiFlow] } });

      await actions.get({ commit });

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetching: true }],
        [types.SET_TRIAGE_FLOWS, [storeFlow]],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Incorrect header' });

      await actions.get({ commit });

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetching: true }],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetching: false }],
      ]);
    });
  });

  describe('#show', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({ data: apiFlow });

      await actions.show({ commit }, 1);

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetchingItem: true }],
        [types.SET_TRIAGE_FLOW, storeFlow],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetchingItem: false }],
      ]);
    });

    it('sends correct actions if API is error', async () => {
      axios.get.mockRejectedValue({ message: 'Not found' });

      await actions.show({ commit }, 1);

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetchingItem: true }],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetchingItem: false }],
      ]);
    });
  });

  describe('#create', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: apiFlow });

      const result = await actions.create(
        { commit },
        {
          name: 'DevClub triage',
          inboxId: 7,
          enabled: true,
          mode: 'shadow',
          definition,
        }
      );

      expect(axios.post).toHaveBeenCalledWith(expect.any(String), {
        triage_flow: {
          name: 'DevClub triage',
          inbox_id: 7,
          enabled: true,
          mode: 'shadow',
          definition,
        },
      });
      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isCreating: true }],
        [types.ADD_TRIAGE_FLOW, storeFlow],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isCreating: false }],
      ]);
      expect(result).toEqual(apiFlow);
    });

    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue(new Error('Validation error'));

      await expect(actions.create({ commit }, {})).rejects.toThrow(Error);

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isCreating: true }],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isCreating: false }],
      ]);
    });
  });

  describe('#update', () => {
    it('sends correct actions if API is success', async () => {
      axios.patch.mockResolvedValue({ data: apiFlow });

      const result = await actions.update(
        { commit },
        { id: 1, name: 'DevClub triage', mode: 'live', definition }
      );

      expect(axios.patch).toHaveBeenCalledWith(expect.any(String), {
        triage_flow: { name: 'DevClub triage', mode: 'live', definition },
      });
      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isUpdating: true }],
        [types.EDIT_TRIAGE_FLOW, storeFlow],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isUpdating: false }],
      ]);
      expect(result).toEqual(apiFlow);
    });

    it('omits definition when only the envelope changes', async () => {
      axios.patch.mockResolvedValue({ data: apiFlow });

      await actions.update({ commit }, { id: 1, enabled: false });

      expect(axios.patch).toHaveBeenCalledWith(expect.any(String), {
        triage_flow: { enabled: false },
      });
    });

    it('sends correct actions if API is error', async () => {
      axios.patch.mockRejectedValue(new Error('Validation error'));

      await expect(actions.update({ commit }, { id: 1 })).rejects.toThrow(
        Error
      );

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isUpdating: true }],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isUpdating: false }],
      ]);
    });
  });

  describe('#delete', () => {
    it('sends correct actions if API is success', async () => {
      axios.delete.mockResolvedValue({});

      await actions.delete({ commit }, 1);

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isDeleting: true }],
        [types.DELETE_TRIAGE_FLOW, 1],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isDeleting: false }],
      ]);
    });

    it('sends correct actions if API is error', async () => {
      axios.delete.mockRejectedValue(new Error('Not found'));

      await expect(actions.delete({ commit }, 1)).rejects.toThrow(Error);

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isDeleting: true }],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isDeleting: false }],
      ]);
    });
  });

  describe('#clone', () => {
    it('sends correct actions if API is success', async () => {
      axios.post.mockResolvedValue({ data: apiFlow });

      const result = await actions.clone({ commit }, { id: 1, inboxId: 12 });

      expect(axios.post).toHaveBeenCalledWith(
        expect.stringContaining('/triage_flows/1/clone'),
        { inbox_id: 12 }
      );
      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isCloning: true }],
        [types.ADD_TRIAGE_FLOW, storeFlow],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isCloning: false }],
      ]);
      expect(result).toEqual(apiFlow);
    });

    it('sends correct actions if API is error', async () => {
      axios.post.mockRejectedValue(new Error('Unsupported channel'));

      await expect(
        actions.clone({ commit }, { id: 1, inboxId: 12 })
      ).rejects.toThrow(Error);

      expect(commit.mock.calls).toEqual([
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isCloning: true }],
        [types.SET_TRIAGE_FLOWS_UI_FLAG, { isCloning: false }],
      ]);
    });
  });

  describe('definition round trip', () => {
    it('keeps the definition byte-for-byte through get -> store -> save', async () => {
      axios.get.mockResolvedValue({ data: { payload: [apiFlow] } });
      await actions.get({ commit });

      const [, [, [stored]]] = commit.mock.calls;
      expect(stored.definition).toEqual(definition);

      commit.mockClear();
      axios.patch.mockResolvedValue({ data: apiFlow });
      await actions.update({ commit }, { id: stored.id, ...stored });

      const [, body] = axios.patch.mock.calls[0];
      expect(body.triage_flow.definition).toEqual(definition);
      expect(JSON.stringify(body.triage_flow.definition)).toBe(
        JSON.stringify(definition)
      );
    });

    it('camelcases the envelope but never the definition', async () => {
      axios.get.mockResolvedValue({ data: apiFlow });

      await actions.show({ commit }, 1);

      const [, [, flow]] = commit.mock.calls;
      expect(flow.createdAt).toBe(1704110400);
      expect(flow.inbox.channelType).toBe('Channel::Whatsapp');
      expect(flow.warnings[0].teamId).toBe(9);
      expect(Object.keys(flow.definition)).toEqual([
        'entry_step_id',
        'steps',
        'no_match',
        'timeout',
      ]);
      expect(flow.definition.steps[0].options[0].next.team_id).toBe(1);
      expect(flow.definition.no_match.max_attempts).toBe(3);
    });
  });
});
