import { mount, shallowMount } from '@vue/test-utils';
import { createStore } from 'vuex';

import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import OptionRow from '../OptionRow.vue';
import RouteEditor from '../RouteEditor.vue';
import StepCard from '../StepCard.vue';
import StepList from '../StepList.vue';
import TriageFlowForm from '../TriageFlowForm.vue';

const buildOption = overrides => ({
  id: '',
  title: '',
  next: null,
  clientKey: 'option-1',
  ...overrides,
});

const mountOptionRow = (option, props = {}) =>
  mount(OptionRow, {
    props: {
      option,
      position: 1,
      stepId: 'root',
      steps: [{ id: 'root', prompt: 'Hi', options: [option] }],
      ...props,
    },
  });

const titleInput = wrapper => wrapper.find('input[type="text"]');

describe('OptionRow', () => {
  it('derives the id from the title the first time an option is named', async () => {
    const wrapper = mountOptionRow(buildOption({ title: 'Dúvidas Técnicas' }));

    await titleInput(wrapper).trigger('blur');

    expect(wrapper.emitted('update')[0][0]).toMatchObject({
      id: 'duvidas_tecnicas',
      title: 'Dúvidas Técnicas',
    });
  });

  it('keeps the id when the title is renamed', async () => {
    const wrapper = mountOptionRow(
      buildOption({ id: 'tecnico', title: 'Technical questions' })
    );

    await titleInput(wrapper).trigger('blur');

    expect(wrapper.emitted('update')).toBeUndefined();
  });

  it('does not derive an id from an empty title', async () => {
    const wrapper = mountOptionRow(buildOption({ title: '' }));

    await titleInput(wrapper).trigger('blur');

    expect(wrapper.emitted('update')).toBeUndefined();
  });

  it('suffixes an id another option in the same step already uses', async () => {
    const wrapper = mountOptionRow(buildOption({ title: 'Financeiro' }), {
      siblingIds: ['financeiro'],
    });

    await titleInput(wrapper).trigger('blur');

    expect(wrapper.emitted('update')[0][0].id).toBe('financeiro_2');
  });

  it('counts title characters in codepoints, the way the channel cap does', () => {
    const wrapper = mountOptionRow(buildOption({ title: '🙂🙂🙂' }), {
      titleMaxLength: 20,
    });

    expect(wrapper.text()).toContain('3/20');
  });
});

describe('RouteEditor', () => {
  const statusCombobox = wrapper => wrapper.findAllComponents(ComboBox)[1];

  it.each(['open', 'pending', 'resolved'])(
    'emits a complete route node for the %s outcome',
    async status => {
      const wrapper = mount(RouteEditor, {
        props: {
          route: { type: 'route', team_id: 4, labels: ['vip'], status: 'open' },
          teamOptions: [{ value: 4, label: 'Support' }],
          labelOptions: [{ value: 'vip', label: 'vip' }],
        },
      });

      statusCombobox(wrapper).vm.$emit('update:modelValue', status);

      expect(wrapper.emitted('update')[0][0]).toEqual({
        type: 'route',
        team_id: 4,
        labels: ['vip'],
        status,
      });
    }
  );

  it('fills in the missing shape when handed an empty destination', async () => {
    const wrapper = mount(RouteEditor, { props: { route: {} } });

    statusCombobox(wrapper).vm.$emit('update:modelValue', 'pending');

    expect(wrapper.emitted('update')[0][0]).toEqual({
      type: 'route',
      team_id: null,
      labels: [],
      status: 'pending',
    });
  });

  // The placeholder reads like a default that is already there, so an empty
  // closing message is the most likely source of "the bot went silent".
  it('warns that an empty closing message leaves the contact with nothing', () => {
    const wrapper = mount(RouteEditor, {
      props: {
        route: { type: 'route', team_id: 4, labels: [], status: 'open' },
      },
    });

    expect(wrapper.text()).toContain('only silence');
  });

  it('drops the silence warning once a closing message is written', () => {
    const wrapper = mount(RouteEditor, {
      props: {
        route: {
          type: 'route',
          team_id: 4,
          labels: [],
          status: 'open',
          message: 'Já te chamo.',
        },
      },
    });

    expect(wrapper.text()).not.toContain('only silence');
  });

  it('flags a route pointing at a team that no longer exists', () => {
    const wrapper = mount(RouteEditor, {
      props: {
        route: { type: 'route', team_id: 9, labels: [], status: 'open' },
        teamOptions: [{ value: 4, label: 'Support' }],
      },
    });

    expect(wrapper.text()).toContain('This team was deleted');
  });

  // Teams load after the form mounts; an empty list is "not loaded yet", not
  // "every team is gone".
  it('says nothing about the team while the team list is still loading', () => {
    const wrapper = mount(RouteEditor, {
      props: {
        route: { type: 'route', team_id: 9, labels: [], status: 'open' },
      },
    });

    expect(wrapper.text()).not.toContain('This team was deleted');
  });
});

describe('StepList', () => {
  const steps = () => [
    {
      id: 'root',
      prompt: 'How can we help?',
      options: [
        {
          id: 'financeiro',
          title: 'Financeiro',
          next: { type: 'step', step_id: 'financeiro' },
        },
        {
          id: 'tecnico',
          title: 'Técnico',
          next: { type: 'route', team_id: 1, labels: [], status: 'open' },
        },
      ],
    },
    {
      id: 'financeiro',
      prompt: 'What about it?',
      options: [
        {
          id: 'outros',
          title: 'Outros',
          next: { type: 'route', team_id: 2, labels: [], status: 'open' },
        },
      ],
    },
  ];

  // Dialog is stubbed away by shallowMount along with the open/close the list
  // calls on it, so it is replaced by a stub that records what it was asked.
  const DialogStub = {
    props: ['description'],
    template: '<div />',
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

  const mountStepList = (props = {}) =>
    shallowMount(StepList, {
      props: { steps: steps(), entryStepId: 'root', ...props },
      global: { stubs: { Dialog: DialogStub } },
    });

  const confirmDialog = wrapper => wrapper.findComponent(DialogStub);

  const cardFor = (wrapper, id) =>
    wrapper
      .findAllComponents(StepCard)
      .find(card => card.props('step').id === id);

  it('pins the entry step first and flags it', () => {
    const wrapper = shallowMount(StepList, {
      props: { steps: steps().reverse(), entryStepId: 'root' },
    });

    const cards = wrapper.findAllComponents(StepCard);
    expect(cards[0].props('step').id).toBe('root');
    expect(cards[0].props('isEntry')).toBe(true);
    expect(cards[1].props('isEntry')).toBe(false);
  });

  it('refuses to delete the entry step', async () => {
    const wrapper = mountStepList();

    cardFor(wrapper, 'root').vm.$emit('delete');

    expect(wrapper.emitted('update')).toBeUndefined();
  });

  // A question carries its options and all their routing, with no undo, behind
  // a small ghost trash icon — so the click has to be confirmed, and the
  // confirmation has to say what goes with it.
  it('asks before deleting a question and says what it takes with it', async () => {
    const wrapper = mountStepList();

    cardFor(wrapper, 'financeiro').vm.$emit('delete');
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('update')).toBeUndefined();
    expect(confirmDialog(wrapper).vm.isOpen).toBe(true);
    expect(confirmDialog(wrapper).props('description')).toContain(
      '1 option(s)'
    );
    expect(confirmDialog(wrapper).props('description')).toContain(
      '1 question(s)'
    );
  });

  it('clears the options that pointed at a deleted step', async () => {
    const wrapper = mountStepList();

    cardFor(wrapper, 'financeiro').vm.$emit('delete');
    await wrapper.vm.$nextTick();
    confirmDialog(wrapper).vm.$emit('confirm');

    const [remaining] = wrapper.emitted('update')[0];
    expect(remaining.map(step => step.id)).toEqual(['root']);
    expect(remaining[0].options[0].next).toBeNull();
    // An option routing to a team is untouched by an unrelated deletion.
    expect(remaining[0].options[1].next).toEqual({
      type: 'route',
      team_id: 1,
      labels: [],
      status: 'open',
    });
  });
});

describe('StepCard', () => {
  const step = {
    id: 'root',
    prompt: 'How can we help?',
    options: [
      { id: 'a', title: 'A', next: null, clientKey: 'option-1' },
      { id: 'b', title: 'B', next: null, clientKey: 'option-2' },
      { id: 'c', title: 'C', next: null, clientKey: 'option-3' },
    ],
  };

  // shallowMount would stub vuedraggable away and with it the #item slot that
  // renders the option rows, so it is replaced by a stub that keeps the slot.
  const DraggableStub = {
    props: ['modelValue'],
    template: `<div>
      <template v-for="(element, index) in modelValue" :key="index">
        <slot name="item" :element="element" :index="index" />
      </template>
    </div>`,
  };

  const mountStepCard = props =>
    shallowMount(StepCard, {
      props: { step, position: 1, ...props },
      global: { stubs: { Draggable: DraggableStub } },
    });

  const addOptionButton = wrapper =>
    wrapper
      .findAll('button-stub')
      .find(button => button.attributes('label') === 'Add option');

  it('hides the delete button on the entry step', () => {
    const entry = mountStepCard({ isEntry: true });
    const other = mountStepCard({ isEntry: false });

    expect(entry.text()).not.toContain('Delete question');
    expect(other.html()).toContain('Delete question');
  });

  it('applies the WhatsApp reply-button cap while a step has three options', () => {
    const wrapper = mountStepCard({ channelType: 'Channel::Whatsapp' });

    expect(
      wrapper.findAllComponents(OptionRow)[0].props('titleMaxLength')
    ).toBe(20);
  });

  // WhatsApp renders four to ten options as a list. Stopping the team at three
  // refused a menu the API saves happily, and there was no way past it.
  it('still lets a fourth option be added to a WhatsApp step', () => {
    const wrapper = mountStepCard({ channelType: 'Channel::Whatsapp' });

    expect(addOptionButton(wrapper).attributes('disabled')).toBe('false');
    expect(wrapper.text()).toContain(
      'switches this channel from buttons to a list'
    );
  });

  it('stops at the ten options WhatsApp can actually render', () => {
    const options = Array.from({ length: 10 }, (unused, index) => ({
      id: `o${index}`,
      title: `O${index}`,
      next: null,
      clientKey: `option-${index}`,
    }));
    const wrapper = mountStepCard({
      channelType: 'Channel::Whatsapp',
      step: { ...step, options },
    });

    expect(addOptionButton(wrapper).attributes('disabled')).toBe('true');
    expect(wrapper.text()).toContain('at most 10 options');
  });

  // The stub used to render the slot and never emit, so the reorder path the
  // drag handle drives was never exercised.
  it('passes a reordered option list straight up to the form', async () => {
    const wrapper = mountStepCard({});
    const reordered = [step.options[2], step.options[0], step.options[1]];

    wrapper
      .findComponent(DraggableStub)
      .vm.$emit('update:modelValue', reordered);
    await wrapper.vm.$nextTick();

    expect(wrapper.emitted('update')[0][0].options.map(o => o.id)).toEqual([
      'c',
      'a',
      'b',
    ]);
  });

  it('hands every option the ids its siblings already use', () => {
    const wrapper = mountStepCard({});

    expect(wrapper.findAllComponents(OptionRow)[0].props('siblingIds')).toEqual(
      ['b', 'c']
    );
  });

  it('shows a warning without turning it into an error', () => {
    const wrapper = mountStepCard({ warnings: ['Nothing leads here.'] });

    expect(wrapper.text()).toContain('Nothing leads here.');
    expect(wrapper.find('.text-n-ruby-11').exists()).toBe(false);
  });
});

describe('TriageFlowForm', () => {
  const inbox = {
    id: 7,
    name: 'WhatsApp DevClub',
    channel_type: 'Channel::Whatsapp',
  };

  const buildStore = () =>
    createStore({
      modules: {
        inboxes: {
          namespaced: true,
          getters: { getInboxes: () => [inbox] },
          actions: { get: vi.fn() },
        },
        teams: {
          namespaced: true,
          getters: { getTeams: () => [{ id: 1, name: 'Support' }] },
          actions: { get: vi.fn() },
        },
        labels: {
          namespaced: true,
          getters: { getLabels: () => [{ title: 'vip' }] },
          actions: { get: vi.fn() },
        },
        triageFlows: {
          namespaced: true,
          getters: { getTriageFlows: () => [] },
        },
      },
    });

  const definition = () => ({
    entry_step_id: 'root',
    steps: [
      {
        id: 'root',
        prompt: 'How can we help?',
        options: [
          {
            id: 'tecnico',
            title: 'A title that is far too long for WhatsApp',
            next: null,
          },
        ],
      },
    ],
    no_match: {
      message: 'Sorry?',
      max_attempts: 3,
      then: { type: 'route', team_id: 1, labels: [], status: 'open' },
    },
    timeout: {
      minutes: 30,
      then: { type: 'route', team_id: 1, labels: [], status: 'open' },
    },
  });

  const mountForm = (initialData = {}) =>
    shallowMount(TriageFlowForm, {
      props: {
        formMode: 'EDIT',
        initialData: {
          name: 'DevClub triage',
          inboxId: 7,
          channelType: 'Channel::Whatsapp',
          enabled: true,
          mode: 'shadow',
          definition: definition(),
          ...initialData,
        },
      },
      global: { plugins: [buildStore()] },
    });

  it('pins each validation error to the step and option it came from', () => {
    const errors = mountForm().findComponent(StepList).props('errors');

    expect(Object.keys(errors)).toEqual(['root']);
    // The WhatsApp cap only reaches the validator if channelType resolves.
    expect(errors.root.messages).toEqual([
      "option titles in step 'root' must be at most 20 characters for this channel",
    ]);
    expect(errors.root.options.tecnico).toEqual([
      "every option in step 'root' needs a destination",
    ]);
  });

  const withoutTimeout = () => {
    const source = definition();
    delete source.timeout;
    return source;
  };

  // A live flow with no timeout leaves a silent contact parked forever, so the
  // rule belongs in the summary the team reads before saving — not only next
  // to the switch it was hidden behind.
  it('reports a live flow with no timeout in the summary', () => {
    const text = mountForm({
      mode: 'live',
      definition: withoutTimeout(),
    }).text();

    expect(text).toContain('a live flow needs a timeout');
  });

  it('reports it once, not again next to the timeout switch', () => {
    const text = mountForm({
      mode: 'live',
      definition: withoutTimeout(),
    }).text();

    expect(text.split('a live flow needs a timeout')).toHaveLength(2);
    expect(text).not.toContain('needs a wait time');
  });

  it('leaves a shadow flow with no timeout alone', () => {
    const text = mountForm({
      mode: 'shadow',
      definition: withoutTimeout(),
    }).text();

    expect(text).not.toContain('a live flow needs a timeout');
  });

  it('warns about a question nothing leads to without blocking the save', () => {
    const orphaned = definition();
    orphaned.steps.push({
      id: 'orfao',
      prompt: 'Anyone there?',
      options: [
        {
          id: 'sim',
          title: 'Sim',
          next: { type: 'route', team_id: 1, labels: [], status: 'open' },
        },
      ],
    });

    const list = mountForm({ definition: orphaned }).findComponent(StepList);

    expect(list.props('warnings')).toEqual({
      orfao: ['No option leads to this question, so nobody is ever asked it.'],
    });
    expect(list.props('errors').orfao).toBeUndefined();
  });

  // Typing 0 used to show "must be between 1 and 5" and then save 3 anyway, so
  // the flow ran on a number nobody chose and the error vanished as if fixed.
  it('submits the zero the team typed rather than a default it never chose', async () => {
    const zeroed = definition();
    zeroed.no_match.max_attempts = 0;
    zeroed.timeout.minutes = 0;
    const wrapper = mountForm({ definition: zeroed });

    await wrapper.find('form').trigger('submit');

    const [payload] = wrapper.emitted('submit')[0];
    expect(payload.definition.no_match.max_attempts).toBe(0);
    expect(payload.definition.timeout.minutes).toBe(0);
  });

  it('falls back to the defaults when the field is left empty', async () => {
    const emptied = definition();
    emptied.no_match.max_attempts = '';
    emptied.timeout.minutes = '';
    const wrapper = mountForm({ definition: emptied });

    await wrapper.find('form').trigger('submit');

    const [payload] = wrapper.emitted('submit')[0];
    expect(payload.definition.no_match.max_attempts).toBe(3);
    expect(payload.definition.timeout.minutes).toBe(30);
  });

  // A server message left standing after the team typed the fix reads as
  // "nothing I do changes this", and pressing Save again to find out is not a
  // free action on a live flow.
  it('drops a server error once the definition it complained about changes', async () => {
    const message = "step 'root' needs a message";
    const wrapper = mountForm();
    await wrapper.setProps({ serverErrors: [message] });

    expect(
      wrapper.findComponent(StepList).props('errors').root.messages
    ).toContain(message);

    wrapper.vm.state.definition.steps[0].prompt = 'Agora sim';
    await wrapper.vm.$nextTick();

    expect(
      wrapper.findComponent(StepList).props('errors').root?.messages || []
    ).not.toContain(message);
  });

  it('strips the client-only drag key before submitting', async () => {
    const wrapper = mountForm();

    await wrapper.find('form').trigger('submit');

    const [payload] = wrapper.emitted('submit')[0];
    expect(payload.definition.steps[0].options[0]).toEqual({
      id: 'tecnico',
      title: 'A title that is far too long for WhatsApp',
      next: null,
    });
    expect(payload.definition.entry_step_id).toBe('root');
  });
});
