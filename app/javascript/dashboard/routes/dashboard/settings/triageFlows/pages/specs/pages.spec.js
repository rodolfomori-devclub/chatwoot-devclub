import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { createRouter, createWebHistory } from 'vue-router';

import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TriageFlowForm from '../../components/TriageFlowForm.vue';
import TriageFlowCreatePage from '../TriageFlowCreatePage.vue';
import TriageFlowEditPage from '../TriageFlowEditPage.vue';
import TriageFlowIndexPage from '../TriageFlowIndexPage.vue';

const flow = {
  id: 1,
  name: 'DevClub triage',
  enabled: true,
  mode: 'shadow',
  version: 4,
  definition: {
    entry_step_id: 'root',
    steps: [{ id: 'root', prompt: 'Hi', options: [] }],
  },
  inbox: { id: 7, name: 'WhatsApp DevClub', channelType: 'Channel::Whatsapp' },
  warnings: [{ type: 'missing_team', teamId: 9 }],
};

const buildStore = () => {
  const dispatched = [];
  const record = key => () => dispatched.push(key);

  const store = createStore({
    modules: {
      triageFlows: {
        namespaced: true,
        getters: {
          getTriageFlows: () => [flow],
          getTriageFlowById: () => () => flow,
          getUIFlags: () => ({}),
        },
        actions: {
          get: record('triageFlows/get'),
          show: record('triageFlows/show'),
        },
      },
      inboxes: {
        namespaced: true,
        getters: {
          getInboxes: () => [
            {
              id: 7,
              name: 'WhatsApp DevClub',
              channel_type: 'Channel::Whatsapp',
            },
            { id: 8, name: 'Website', channel_type: 'Channel::WebWidget' },
          ],
        },
        actions: { get: record('inboxes/get') },
      },
      teams: {
        namespaced: true,
        getters: { getTeams: () => [] },
        actions: { get: record('teams/get') },
      },
      labels: {
        namespaced: true,
        getters: { getLabels: () => [] },
        actions: { get: record('labels/get') },
      },
    },
  });

  return { store, dispatched };
};

const buildRouter = () =>
  createRouter({
    history: createWebHistory(),
    routes: [
      {
        path: '/',
        name: 'triage_flows_index',
        component: { template: '<div />' },
      },
      {
        path: '/new',
        name: 'triage_flows_new',
        component: { template: '<div />' },
      },
      {
        path: '/edit/:id',
        name: 'triage_flows_edit',
        component: { template: '<div />' },
      },
    ],
  });

// shallowMount would stub SettingsLayout and with it every named slot the
// pages put their content in, leaving nothing to assert on.
const SettingsLayoutStub = {
  template: '<div><slot name="header" /><slot name="body" /><slot /></div>',
};

const slotOnly = { template: '<div><slot /></div>' };

const mountPage = async (component, path = '/') => {
  const { store, dispatched } = buildStore();
  const router = buildRouter();
  await router.push(path);
  await router.isReady();

  const wrapper = shallowMount(component, {
    global: {
      plugins: [store, router],
      stubs: {
        SettingsLayout: SettingsLayoutStub,
        CardLayout: slotOnly,
        Dialog: slotOnly,
      },
    },
  });

  return { wrapper, dispatched };
};

describe('triage flow pages', () => {
  it('loads the list and the inboxes it needs to offer a clone target', async () => {
    const { wrapper, dispatched } = await mountPage(TriageFlowIndexPage);

    expect(dispatched).toEqual(['triageFlows/get', 'inboxes/get']);
    expect(wrapper.html()).toContain('WhatsApp DevClub');
  });

  // A count alone makes the team open every flow to find out what is wrong.
  it('names the problem behind a warning count', async () => {
    const { wrapper } = await mountPage(TriageFlowIndexPage);

    expect(wrapper.text()).toContain('1 thing to fix');
    expect(wrapper.text()).toContain(
      'A route still sends conversations to team 9, which was deleted.'
    );
  });

  it('offers the inboxes that have no flow yet as clone targets', async () => {
    const { wrapper } = await mountPage(TriageFlowIndexPage);

    const combobox = wrapper.findComponent(ComboBox);
    expect(combobox.props('options')).toEqual([
      { value: 8, label: 'Website · livechat' },
    ]);
  });

  it('mounts the create page without a flow to hydrate from', async () => {
    const { wrapper, dispatched } = await mountPage(
      TriageFlowCreatePage,
      '/new'
    );

    expect(dispatched).toEqual(['triageFlows/get']);
    expect(wrapper.findComponent(TriageFlowForm).props('formMode')).toBe(
      'CREATE'
    );
  });

  it('hands the edit page the stored flow, definition untouched', async () => {
    const { wrapper } = await mountPage(TriageFlowEditPage, '/edit/1');

    const form = wrapper.findComponent(TriageFlowForm);
    expect(form.props('formMode')).toBe('EDIT');
    expect(form.props('initialData')).toEqual({
      name: 'DevClub triage',
      inboxId: 7,
      channelType: 'Channel::Whatsapp',
      enabled: true,
      mode: 'shadow',
      definition: flow.definition,
    });
  });
});
