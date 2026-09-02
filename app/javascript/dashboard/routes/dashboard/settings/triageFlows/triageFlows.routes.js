import { FEATURE_FLAGS } from '../../../../featureFlags';
import { frontendURL } from '../../../../helper/URLHelper';
import SettingsWrapper from '../SettingsWrapper.vue';
import TriageFlowIndex from './pages/TriageFlowIndexPage.vue';
import TriageFlowCreate from './pages/TriageFlowCreatePage.vue';
import TriageFlowEdit from './pages/TriageFlowEditPage.vue';

export default {
  routes: [
    {
      path: frontendURL('accounts/:accountId/settings/triage-flows'),
      component: SettingsWrapper,
      children: [
        {
          path: '',
          redirect: to => {
            return { name: 'triage_flows_index', params: to.params };
          },
        },
        {
          path: 'list',
          name: 'triage_flows_index',
          component: TriageFlowIndex,
          meta: {
            featureFlag: FEATURE_FLAGS.TRIAGE_FLOWS,
            permissions: ['administrator'],
          },
        },
        {
          path: 'new',
          name: 'triage_flows_new',
          component: TriageFlowCreate,
          meta: {
            featureFlag: FEATURE_FLAGS.TRIAGE_FLOWS,
            permissions: ['administrator'],
          },
        },
        {
          path: 'edit/:id',
          name: 'triage_flows_edit',
          component: TriageFlowEdit,
          meta: {
            featureFlag: FEATURE_FLAGS.TRIAGE_FLOWS,
            permissions: ['administrator'],
          },
        },
      ],
    },
  ],
};
