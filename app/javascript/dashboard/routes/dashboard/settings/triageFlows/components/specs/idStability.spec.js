import { mount } from '@vue/test-utils';
import { createStore } from 'vuex';

import OptionRow from '../OptionRow.vue';
import TriageFlowForm from '../TriageFlowForm.vue';

// An option id is what the contact's reply is matched against, and open
// sessions hold the id they were shown. Renaming a title in the builder must
// therefore never repoint an id: a live customer halfway through a menu would
// stop matching. These run the whole editor — form, step list, step card,
// option row — so the guarantee is proven on the path a person actually takes.
const DraggableStub = {
  props: ['modelValue'],
  template: `<div>
    <template v-for="(element, index) in modelValue" :key="index">
      <slot name="item" :element="element" :index="index" />
    </template>
  </div>`,
};

const route = () => ({
  type: 'route',
  team_id: 1,
  labels: [],
  status: 'open',
});

const buildStore = () =>
  createStore({
    modules: {
      inboxes: {
        namespaced: true,
        getters: {
          getInboxes: () => [
            { id: 7, name: 'Widget', channel_type: 'Channel::WebWidget' },
          ],
        },
        actions: { get: vi.fn() },
      },
      teams: {
        namespaced: true,
        getters: { getTeams: () => [{ id: 1, name: 'Support' }] },
        actions: { get: vi.fn() },
      },
      labels: {
        namespaced: true,
        getters: { getLabels: () => [] },
        actions: { get: vi.fn() },
      },
      triageFlows: { namespaced: true, getters: { getTriageFlows: () => [] } },
    },
  });

const mountForm = options =>
  mount(TriageFlowForm, {
    props: {
      formMode: 'EDIT',
      initialData: {
        name: 'DevClub triage',
        inboxId: 7,
        channelType: 'Channel::WebWidget',
        enabled: false,
        mode: 'shadow',
        definition: {
          entry_step_id: 'root',
          steps: [{ id: 'root', prompt: 'How can we help?', options }],
          no_match: { message: 'Sorry?', max_attempts: 3, then: route() },
          timeout: { minutes: 30, then: route() },
        },
      },
    },
    global: {
      plugins: [buildStore()],
      stubs: { Draggable: DraggableStub, ChannelPreview: true },
    },
  });

const optionRowAt = (wrapper, index) =>
  wrapper.findAllComponents(OptionRow)[index];

const rename = async (wrapper, index, title) => {
  const input = optionRowAt(wrapper, index).find('input[type="text"]');
  await input.setValue(title);
  await input.trigger('blur');
};

const submittedOptions = async wrapper => {
  await wrapper.find('form').trigger('submit');
  const [payload] = wrapper.emitted('submit').at(-1);
  return payload.definition.steps[0].options;
};

describe('option id stability', () => {
  it('keeps a saved id when the title is rewritten', async () => {
    const wrapper = mountForm([
      { id: 'renovacao', title: 'Renovação', next: route() },
    ]);

    await rename(wrapper, 0, 'Renovação de assinatura');

    expect(await submittedOptions(wrapper)).toEqual([
      { id: 'renovacao', title: 'Renovação de assinatura', next: route() },
    ]);
  });

  it('derives an id once for a new option and freezes it across renames', async () => {
    const wrapper = mountForm([{ id: '', title: '', next: route() }]);

    await rename(wrapper, 0, 'Financeiro');
    expect(optionRowAt(wrapper, 0).props('option').id).toBe('financeiro');

    await rename(wrapper, 0, 'Setor Financeiro');
    await rename(wrapper, 0, 'Cobrança');

    expect(await submittedOptions(wrapper)).toEqual([
      { id: 'financeiro', title: 'Cobrança', next: route() },
    ]);
  });

  it('never lets a rename collide two options onto one id', async () => {
    const wrapper = mountForm([
      { id: '', title: '', next: route() },
      { id: '', title: '', next: route() },
    ]);

    await rename(wrapper, 0, 'Renovação');
    await rename(wrapper, 1, 'renovacao');

    // Same slug, different options: the second one is suffixed and both keep
    // what they were given even after the titles are swapped around.
    await rename(wrapper, 0, 'Outra coisa');

    expect(await submittedOptions(wrapper)).toEqual([
      { id: 'renovacao', title: 'Outra coisa', next: route() },
      { id: 'renovacao_2', title: 'renovacao', next: route() },
    ]);
  });

  it('derives an id at submit for a title never blurred, without touching the others', async () => {
    const wrapper = mountForm([
      { id: 'tecnico', title: 'Técnico', next: route() },
      { id: '', title: '', next: route() },
    ]);

    // setValue without blur: the id is still empty in state at submit time.
    await optionRowAt(wrapper, 1)
      .find('input[type="text"]')
      .setValue('Técnico');

    expect(await submittedOptions(wrapper)).toEqual([
      { id: 'tecnico', title: 'Técnico', next: route() },
      { id: 'tecnico_2', title: 'Técnico', next: route() },
    ]);
  });
});
