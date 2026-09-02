import * as MutationHelpers from 'shared/helpers/vuex/mutationHelpers';
import types from '../mutation-types';
import TriageFlowsAPI from '../../api/triageFlows';
import { parseAPIErrorResponse, throwErrorMessage } from '../utils/api';
import camelcaseKeys from 'camelcase-keys';
import snakecaseKeys from 'snakecase-keys';

// `definition` is a wire contract with the backend and the triage engine
// (entry_step_id, step_id, no_match, max_attempts, team_id). Re-casing it in
// either direction would break the flow, so it is lifted out of the envelope
// and passed through byte-for-byte.
const deserializeFlow = ({ definition, ...flow }) => ({
  ...camelcaseKeys(flow, { deep: true }),
  definition,
});

const serializeFlow = ({ definition, ...flow }) => {
  const params = snakecaseKeys(flow, { deep: true });
  if (definition) {
    params.definition = definition;
  }
  return params;
};

// A rejected save is two things at once: one line for the toast and, when the
// definition validator refuses, the per-rule list the editor pins to each step.
// A 422 names the attribute that failed — `definition` for a validator rule,
// `inbox_id` when the target inbox already has a flow — and
// parseAPIErrorResponse only understands `errors` as an array, so either shape
// reaches the toast as the literal string "undefined". Flatten the hash for
// the message and carry the definition list across for the editor.
const flowError = error => {
  const errors = error?.response?.data?.errors;
  const definitionErrors = errors?.definition ?? [];
  const messages = Array.isArray(errors)
    ? errors
    : Object.values(errors || {}).flat();
  const parsed = parseAPIErrorResponse(error);
  const failure = new Error(messages[0] || parsed?.message || parsed);
  failure.definitionErrors = definitionErrors;
  return failure;
};

export const state = {
  records: [],
  uiFlags: {
    isFetching: false,
    isFetchingItem: false,
    isCreating: false,
    isUpdating: false,
    isDeleting: false,
    isCloning: false,
  },
};

export const getters = {
  getTriageFlows(_state) {
    return _state.records;
  },
  getUIFlags(_state) {
    return _state.uiFlags;
  },
  getTriageFlowById: _state => id => {
    return _state.records.find(record => record.id === Number(id)) || {};
  },
};

export const actions = {
  get: async function get({ commit }) {
    commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetching: true });
    try {
      const response = await TriageFlowsAPI.get();
      commit(
        types.SET_TRIAGE_FLOWS,
        response.data.payload.map(deserializeFlow)
      );
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetching: false });
    }
  },

  show: async function show({ commit }, flowId) {
    commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetchingItem: true });
    try {
      const response = await TriageFlowsAPI.show(flowId);
      commit(types.SET_TRIAGE_FLOW, deserializeFlow(response.data));
    } catch (error) {
      throwErrorMessage(error);
    } finally {
      commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isFetchingItem: false });
    }
  },

  create: async function create({ commit }, flowObj) {
    commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isCreating: true });
    try {
      const response = await TriageFlowsAPI.create({
        triage_flow: serializeFlow(flowObj),
      });
      commit(types.ADD_TRIAGE_FLOW, deserializeFlow(response.data));
      return response.data;
    } catch (error) {
      throw flowError(error);
    } finally {
      commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isCreating: false });
    }
  },

  update: async function update({ commit }, { id, ...flowParams }) {
    commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isUpdating: true });
    try {
      const response = await TriageFlowsAPI.update(id, {
        triage_flow: serializeFlow(flowParams),
      });
      commit(types.EDIT_TRIAGE_FLOW, deserializeFlow(response.data));
      return response.data;
    } catch (error) {
      throw flowError(error);
    } finally {
      commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isUpdating: false });
    }
  },

  delete: async function deleteFlow({ commit }, flowId) {
    commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isDeleting: true });
    try {
      await TriageFlowsAPI.delete(flowId);
      commit(types.DELETE_TRIAGE_FLOW, flowId);
    } catch (error) {
      throw flowError(error);
    } finally {
      commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isDeleting: false });
    }
  },

  clone: async function clone({ commit }, { id, inboxId }) {
    commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isCloning: true });
    try {
      const response = await TriageFlowsAPI.clone(id, inboxId);
      commit(types.ADD_TRIAGE_FLOW, deserializeFlow(response.data));
      return response.data;
    } catch (error) {
      throw flowError(error);
    } finally {
      commit(types.SET_TRIAGE_FLOWS_UI_FLAG, { isCloning: false });
    }
  },
};

export const mutations = {
  [types.SET_TRIAGE_FLOWS_UI_FLAG](_state, data) {
    _state.uiFlags = {
      ..._state.uiFlags,
      ...data,
    };
  },

  [types.SET_TRIAGE_FLOWS]: MutationHelpers.set,
  [types.SET_TRIAGE_FLOW]: MutationHelpers.setSingleRecord,
  [types.ADD_TRIAGE_FLOW]: MutationHelpers.create,
  [types.EDIT_TRIAGE_FLOW]: MutationHelpers.update,
  [types.DELETE_TRIAGE_FLOW]: MutationHelpers.destroy,
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
