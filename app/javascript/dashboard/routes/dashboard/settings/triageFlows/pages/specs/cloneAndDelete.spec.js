import { shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';
import { createRouter, createWebHistory } from 'vue-router';

import messages from 'dashboard/i18n/locale/en/triageFlows.json';
import TriageFlowIndexPage from '../TriageFlowIndexPage.vue';

const alerts = [];
vi.mock('dashboard/composables', () => ({
  useAlert: message => alerts.push(message),
}));

const flow = {
  id: 1,
  name: 'DevClub triage',
  enabled: false,
  mode: 'shadow',
  definition: { entry_step_id: 'root', steps: [{ id: 'root', options: [] }] },
  inbox: { id: 7, name: 'WhatsApp DevClub', channelType: 'Channel::Whatsapp' },
  warnings: [],
};

const buildStore = ({ clone, remove } = {}) =>
  createStore({
    modules: {
      triageFlows: {
        namespaced: true,
        getters: {
          getTriageFlows: () => [flow],
          getTriageFlowById: () => () => flow,
          getUIFlags: () => ({}),
        },
        actions: {
          get: vi.fn(),
          clone: clone || vi.fn(),
          delete: remove || vi.fn(),
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
        actions: { get: vi.fn() },
      },
    },
  });

const buildRouter = () =>
  createRouter({
    history: createWebHistory(),
    routes: [
      {
        path: '/',
        name: 'triage_flows_index',
        component: { render: () => null },
      },
      {
        path: '/new',
        name: 'triage_flows_new',
        component: { render: () => null },
      },
      {
        path: '/edit/:id',
        name: 'triage_flows_edit',
        component: { render: () => null },
      },
    ],
  });

// The real Dialog is a teleported modal; only open/close and the confirm event
// matter here, and both are exercised rather than stubbed away.
const DialogStub = {
  name: 'DialogStub',
  template: '<div><slot /></div>',
  data: () => ({ isOpen: false }),
  methods: {
    open() {
      this.isOpen = true;
    },
    close() {
      this.isOpen = false;
    },
  },
};

// shallowMount drops slot content, and both dialogs live in the layout's
// default slot, so the layout is replaced by a stub that renders its slots.
const LayoutStub = {
  name: 'LayoutStub',
  template: '<div><slot name="header" /><slot name="body" /><slot /></div>',
};

const mountIndex = store =>
  shallowMount(TriageFlowIndexPage, {
    global: {
      plugins: [store, buildRouter()],
      stubs: { Dialog: DialogStub, SettingsLayout: LayoutStub },
    },
  });

const dialogs = wrapper => wrapper.findAllComponents({ name: 'DialogStub' });
const deleteDialog = wrapper => dialogs(wrapper)[0];
const cloneDialog = wrapper => dialogs(wrapper)[1];

const flush = () =>
  new Promise(resolve => {
    setTimeout(resolve, 0);
  });

describe('TriageFlowIndexPage clone and delete', () => {
  beforeEach(() => {
    alerts.length = 0;
  });

  // A dialog has nowhere to pin an inline error, so the toast is the only place
  // the reason can appear. "Could not clone the flow" leaves the team with no
  // idea that a title is too long for the channel they picked.
  it('shows why the API refused a clone and keeps the dialog open', async () => {
    const message =
      "option titles in step 'root' must be at most 20 characters for this channel";
    const wrapper = mountIndex(
      buildStore({ clone: () => Promise.reject(new Error(message)) })
    );
    const dialog = cloneDialog(wrapper);
    dialog.vm.open();

    dialog.vm.$emit('confirm');
    await flush();

    expect(alerts).toEqual([message]);
    expect(dialog.vm.isOpen).toBe(true);
  });

  // Driven through openDeleteDialog so activeFlowId is really populated: the
  // example used to pass with the id still null, which would have hidden a
  // delete that 404s at runtime.
  it('shows why the API refused a delete', async () => {
    const remove = vi.fn(() => Promise.reject(new Error('Flow not found')));
    const wrapper = mountIndex(buildStore({ remove }));

    wrapper.vm.openDeleteDialog(flow.id);
    deleteDialog(wrapper).vm.$emit('confirm');
    await flush();

    expect(remove).toHaveBeenCalledWith(expect.anything(), flow.id);
    expect(alerts).toEqual(['Flow not found']);
  });

  it('confirms and closes on a clone that went through', async () => {
    const clone = vi.fn(() => Promise.resolve(flow));
    const wrapper = mountIndex(buildStore({ clone }));
    const dialog = cloneDialog(wrapper);
    wrapper.vm.openCloneDialog(flow.id);
    wrapper.vm.cloneInboxId = 8;
    dialog.vm.open();

    dialog.vm.$emit('confirm');
    await flush();

    expect(clone).toHaveBeenCalledWith(expect.anything(), {
      id: flow.id,
      inboxId: 8,
    });
    expect(alerts).toEqual([messages.TRIAGE_FLOWS.CLONE.API.SUCCESS_MESSAGE]);
    expect(dialog.vm.isOpen).toBe(false);
  });

  // Names alone gave no way to see a cross-channel clone coming; the API
  // refuses it with a toast about "the target channel".
  it('names the channel of every inbox that has no flow yet', () => {
    const wrapper = mountIndex(buildStore());

    expect(wrapper.vm.availableInboxOptions).toEqual([
      { value: 8, label: 'Website · livechat' },
    ]);
  });
});
