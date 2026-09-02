/* global axios */

import ApiClient from './ApiClient';

class TriageFlows extends ApiClient {
  constructor() {
    super('triage_flows', { accountScoped: true });
  }

  clone(id, inboxId) {
    return axios.post(`${this.url}/${id}/clone`, { inbox_id: inboxId });
  }
}

export default new TriageFlows();
