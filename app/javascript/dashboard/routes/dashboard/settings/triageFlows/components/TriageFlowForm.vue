<script setup>
import { computed, onMounted, reactive, ref, watch } from 'vue';
import { onBeforeRouteLeave } from 'vue-router';
import { useI18n } from 'vue-i18n';
import { useStore, useMapGetter } from 'dashboard/composables/store';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import Switch from 'dashboard/components-next/switch/Switch.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import ChannelPreview from './ChannelPreview.vue';
import RouteEditor from './RouteEditor.vue';
import StepList from './StepList.vue';

import {
  emptyOption,
  emptyStep,
  slugify,
  uniqueId,
  validateDefinition,
} from '../helpers/definition';

const props = defineProps({
  formMode: {
    type: String,
    required: true,
    validator: value => ['CREATE', 'EDIT'].includes(value),
  },
  initialData: { type: Object, default: () => ({}) },
  isLoading: { type: Boolean, default: false },
  serverErrors: { type: Array, default: () => [] },
});

const emit = defineEmits(['submit']);

const { t } = useI18n();
const store = useStore();

const DEFAULT_MAX_ATTEMPTS = 3;
const DEFAULT_TIMEOUT_MINUTES = 30;
const NO_MATCH_MESSAGE_MAX_LENGTH = 1024;

// Draggable needs an identity that survives an id being derived from a title,
// so every option carries a client-only key that is stripped before submit.
let clientKeySeed = 0;
const nextClientKey = () => {
  clientKeySeed += 1;
  return `option-${clientKeySeed}`;
};

// Number('') is 0 and 0 is falsy, so `Number(x) || DEFAULT` used to answer the
// live "must be between 1 and 5" error and then save 3 anyway. Only a value
// the team did not type falls back.
const numberOr = (value, fallback) => {
  const parsed = Number(value);
  return String(value ?? '').trim() === '' || Number.isNaN(parsed)
    ? fallback
    : parsed;
};

const buildRoute = () => ({
  type: 'route',
  team_id: null,
  labels: [],
  status: 'open',
});

const buildOption = () => ({ ...emptyOption(), clientKey: nextClientKey() });

const buildStep = id => {
  const step = { ...emptyStep(), id };
  return {
    ...step,
    options: (step.options || []).map(option => ({
      ...option,
      clientKey: nextClientKey(),
    })),
  };
};

const buildDefaultDefinition = () => ({
  entry_step_id: 'root',
  steps: [buildStep('root')],
  no_match: {
    message: '',
    max_attempts: DEFAULT_MAX_ATTEMPTS,
    then: buildRoute(),
  },
  timeout: { minutes: DEFAULT_TIMEOUT_MINUTES, then: buildRoute() },
});

const hydrate = definition => {
  if (!definition) return buildDefaultDefinition();

  return {
    ...definition,
    steps: (definition.steps || []).map(step => ({
      ...step,
      options: (step.options || []).map(option => ({
        ...option,
        clientKey: nextClientKey(),
      })),
    })),
    no_match: definition.no_match || {
      message: '',
      max_attempts: DEFAULT_MAX_ATTEMPTS,
      then: buildRoute(),
    },
    timeout: definition.timeout || null,
  };
};

const state = reactive({
  name: '',
  inboxId: '',
  enabled: false,
  mode: 'shadow',
  definition: buildDefaultDefinition(),
});

const isEdit = computed(() => props.formMode === 'EDIT');

const inboxes = useMapGetter('inboxes/getInboxes');
const teams = useMapGetter('teams/getTeams');
const labels = useMapGetter('labels/getLabels');
const flows = useMapGetter('triageFlows/getTriageFlows');

const usedInboxIds = computed(
  () => new Set(flows.value.map(flow => flow.inbox?.id))
);

const inboxOptions = computed(() =>
  inboxes.value
    .filter(inbox => isEdit.value || !usedInboxIds.value.has(inbox.id))
    .map(inbox => ({ value: inbox.id, label: inbox.name }))
);

const teamOptions = computed(() =>
  teams.value.map(team => ({ value: team.id, label: team.name }))
);

const labelOptions = computed(() =>
  labels.value.map(label => ({ value: label.title, label: label.title }))
);

// The inboxes store keeps records exactly as the API sends them (channel_type),
// while a flow's nested inbox comes back camelCased by the triageFlows store.
const channelType = computed(
  () =>
    inboxes.value.find(inbox => inbox.id === state.inboxId)?.channel_type ||
    props.initialData.channelType ||
    ''
);

const modeOptions = computed(() => [
  { value: 'shadow', label: t('TRIAGE_FLOWS.FORM.MODE.SHADOW.LABEL') },
  { value: 'live', label: t('TRIAGE_FLOWS.FORM.MODE.LIVE.LABEL') },
]);

const modeDescription = computed(() =>
  state.mode === 'live'
    ? t('TRIAGE_FLOWS.FORM.MODE.LIVE.DESCRIPTION')
    : t('TRIAGE_FLOWS.FORM.MODE.SHADOW.DESCRIPTION')
);

const isTimeoutEnabled = computed(() => Boolean(state.definition.timeout));

// validateDefinition anchors each error to a dotted path
// (steps.<stepId>.options.<optionId>.next); the cards want the ids on their own
// so a message can be rendered next to the field that caused it.
const issueFromPath = ({ path, message }) => {
  const parts = String(path).split('.');
  if (parts[0] !== 'steps' || parts.length < 3) return { path, message };
  if (parts[2] !== 'options' || parts.length < 5) {
    return { path, message, stepId: parts[1] };
  }
  return { path, message, stepId: parts[1], optionId: parts[3] };
};

// The mode is part of the rules: a live flow with no timeout can strand a
// silent contact forever. It is reported once, from here, so the summary box
// carries it like every other rule instead of a second line next to the
// timeout switch saying the same thing.
const validation = computed(() =>
  validateDefinition(state.definition, channelType.value, { mode: state.mode })
);

const definitionIssues = computed(() =>
  validation.value.errors.map(issueFromPath)
);

// Warnings are not errors: a flow with a question nothing leads to still has
// to save, so they travel beside the issues and never reach topLevelErrors.
const stepWarnings = computed(() =>
  validation.value.warnings
    .filter(warning => warning.type === 'unreachable_step')
    .reduce(
      (acc, { stepId }) => ({
        ...acc,
        [stepId]: [t('TRIAGE_FLOWS.STEPS.WARNINGS.UNREACHABLE')],
      }),
      {}
    )
);

const stepIds = computed(() =>
  state.definition.steps.map(step => step.id).filter(Boolean)
);

// Server messages arrive as sentences naming the offending step, so pin them
// to that step's card when its id shows up in the text.
// The server repeats itself only on the next save, so a message left standing
// after the team has typed the fix reads as "nothing I do changes this".
const areServerErrorsStale = ref(false);

const serverIssues = computed(() =>
  (areServerErrorsStale.value ? [] : props.serverErrors).map(message => ({
    message,
    stepId: stepIds.value.find(id => new RegExp(`\\b${id}\\b`).test(message)),
  }))
);

const issues = computed(() => [
  ...definitionIssues.value,
  ...serverIssues.value,
]);

const stepErrors = computed(() =>
  issues.value.reduce((acc, { message, stepId, optionId }) => {
    if (!stepId) return acc;

    const entry = acc[stepId] || { messages: [], options: {} };
    if (optionId) {
      entry.options[optionId] = [...(entry.options[optionId] || []), message];
    } else {
      entry.messages = [...entry.messages, message];
    }
    return { ...acc, [stepId]: entry };
  }, {})
);

// The API repeats a rule the client already caught, so the same sentence can
// arrive twice; the summary is a checklist and each line has to appear once.
const topLevelErrors = computed(() => [
  ...new Set(
    issues.value.filter(issue => !issue.stepId).map(issue => issue.message)
  ),
]);

const submitLabel = computed(() =>
  isEdit.value ? t('TRIAGE_FLOWS.EDIT.SUBMIT') : t('TRIAGE_FLOWS.CREATE.SUBMIT')
);

const isSubmitDisabled = computed(
  () => !state.name.trim() || !state.inboxId || props.isLoading
);

const updateDefinition = changes => {
  state.definition = { ...state.definition, ...changes };
};

const handleStepsUpdate = steps => updateDefinition({ steps });

const uniqueStepId = base => {
  const taken = new Set(stepIds.value);
  if (base && !taken.has(base)) return base;

  let index = taken.size + 1;
  while (taken.has(`step_${index}`)) index += 1;
  return `step_${index}`;
};

const handleAddStep = () =>
  handleStepsUpdate([...state.definition.steps, buildStep(uniqueStepId(''))]);

const handleAddOption = stepId =>
  handleStepsUpdate(
    state.definition.steps.map(step =>
      step.id === stepId
        ? { ...step, options: [...step.options, buildOption()] }
        : step
    )
  );

// "Create a new step" from an option: spawn the step and wire the option to it
// in one go, so the team never has to hand-match ids.
const handleCreateStep = ({ stepId, optionKey }) => {
  const parent = state.definition.steps.find(step => step.id === stepId);
  const option = parent?.options.find(item => item.clientKey === optionKey);
  // An untitled option has nothing to slugify, so fall back to step_2, step_3…
  const newStepId = uniqueStepId(option?.title ? slugify(option.title) : '');

  const steps = state.definition.steps.map(step =>
    step.id === stepId
      ? {
          ...step,
          options: step.options.map(item =>
            item.clientKey === optionKey
              ? { ...item, next: { type: 'step', step_id: newStepId } }
              : item
          ),
        }
      : step
  );

  handleStepsUpdate([...steps, buildStep(newStepId)]);
};

const updateNoMatch = changes =>
  updateDefinition({
    no_match: { ...state.definition.no_match, ...changes },
  });

const updateTimeout = changes =>
  updateDefinition({ timeout: { ...state.definition.timeout, ...changes } });

const handleTimeoutToggle = enabled =>
  updateDefinition({
    timeout: enabled
      ? { minutes: DEFAULT_TIMEOUT_MINUTES, then: buildRoute() }
      : null,
  });

const normalizeDefinition = () => {
  const { steps, no_match: noMatch, timeout } = state.definition;

  return {
    ...state.definition,
    steps: steps.map(step => {
      // An option only gets its id on blur, so anything still unnamed at submit
      // time is slugified here — de-duplicated, because two options in one step
      // sharing an id is the one thing the matcher cannot recover from.
      const taken = step.options.map(option => option.id).filter(Boolean);
      return {
        id: step.id,
        prompt: step.prompt,
        options: step.options.map(option => {
          const id = option.id || uniqueId(slugify(option.title), taken);
          taken.push(id);
          return { id, title: option.title, next: option.next };
        }),
      };
    }),
    no_match: {
      ...noMatch,
      max_attempts: numberOr(noMatch.max_attempts, DEFAULT_MAX_ATTEMPTS),
    },
    timeout: timeout
      ? {
          ...timeout,
          minutes: numberOr(timeout.minutes, DEFAULT_TIMEOUT_MINUTES),
        }
      : null,
  };
};

const savedSnapshot = ref('');
const snapshot = () =>
  JSON.stringify({ ...state, definition: normalizeDefinition() });
const isDirty = () => snapshot() !== savedSnapshot.value;

const handleSubmit = () => {
  savedSnapshot.value = snapshot();
  emit('submit', {
    name: state.name,
    inboxId: state.inboxId,
    enabled: state.enabled,
    mode: state.mode,
    definition: normalizeDefinition(),
  });
};

watch(
  () => props.serverErrors,
  () => {
    areServerErrorsStale.value = false;
  }
);

watch(
  () => state.definition,
  () => {
    areServerErrorsStale.value = true;
  },
  { deep: true }
);

// Twenty minutes of menu building lives in this component's local state and
// nothing else, so a stray breadcrumb click used to throw all of it away.

onBeforeRouteLeave(() => {
  // eslint-disable-next-line no-alert
  return !isDirty() || window.confirm(t('TRIAGE_FLOWS.FORM.LEAVE_CONFIRM'));
});

watch(
  () => props.initialData,
  data => {
    state.name = data.name || '';
    state.inboxId = data.inboxId ?? '';
    state.enabled = Boolean(data.enabled);
    state.mode = data.mode || 'shadow';
    state.definition = hydrate(data.definition);
    savedSnapshot.value = snapshot();
  },
  { immediate: true }
);

onMounted(() => {
  store.dispatch('inboxes/get');
  store.dispatch('teams/get');
  store.dispatch('labels/get');
});
</script>

<template>
  <form
    class="grid grid-cols-1 gap-8 xl:grid-cols-[minmax(0,1fr)_20rem]"
    @submit.prevent="handleSubmit"
  >
    <div class="flex flex-col gap-6">
      <div
        v-if="topLevelErrors.length"
        class="flex flex-col gap-2 p-4 rounded-xl bg-n-ruby-9/10"
      >
        <span class="text-sm font-medium text-n-ruby-11">
          {{ t('TRIAGE_FLOWS.FORM.ERRORS.TITLE') }}
        </span>
        <ul class="flex flex-col gap-1 mb-0 list-none">
          <li
            v-for="error in topLevelErrors"
            :key="error"
            class="text-sm text-n-ruby-11"
          >
            {{ error }}
          </li>
        </ul>
      </div>

      <Input
        v-model="state.name"
        :label="t('TRIAGE_FLOWS.FORM.NAME.LABEL')"
        :placeholder="t('TRIAGE_FLOWS.FORM.NAME.PLACEHOLDER')"
      />

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('TRIAGE_FLOWS.FORM.INBOX.LABEL') }}
        </label>
        <ComboBox
          v-model="state.inboxId"
          :options="inboxOptions"
          :disabled="isEdit"
          :placeholder="t('TRIAGE_FLOWS.FORM.INBOX.PLACEHOLDER')"
          :search-placeholder="t('TRIAGE_FLOWS.FORM.INBOX.SEARCH_PLACEHOLDER')"
          :empty-state="t('TRIAGE_FLOWS.FORM.INBOX.EMPTY_STATE')"
          :message="
            isEdit
              ? t('TRIAGE_FLOWS.FORM.INBOX.LOCKED_HINT')
              : t('TRIAGE_FLOWS.FORM.INBOX.HINT')
          "
        />
      </div>

      <div class="flex items-start justify-between gap-4">
        <div class="flex flex-col gap-1">
          <span class="text-sm font-medium text-n-slate-12">
            {{ t('TRIAGE_FLOWS.FORM.ENABLED.LABEL') }}
          </span>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('TRIAGE_FLOWS.FORM.ENABLED.DESCRIPTION') }}
          </p>
        </div>
        <Switch v-model="state.enabled" class="mt-1" />
      </div>

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('TRIAGE_FLOWS.FORM.MODE.LABEL') }}
        </label>
        <ComboBox
          v-model="state.mode"
          :options="modeOptions"
          :message="modeDescription"
        />
      </div>

      <StepList
        :steps="state.definition.steps"
        :entry-step-id="state.definition.entry_step_id"
        :team-options="teamOptions"
        :label-options="labelOptions"
        :channel-type="channelType"
        :errors="stepErrors"
        :warnings="stepWarnings"
        @update="handleStepsUpdate"
        @add-step="handleAddStep"
        @add-option="handleAddOption"
        @create-step="handleCreateStep"
      />

      <div class="flex flex-col gap-4 pt-6 border-t border-n-weak">
        <div class="flex flex-col gap-1">
          <span class="text-sm font-medium text-n-slate-12">
            {{ t('TRIAGE_FLOWS.FORM.NO_MATCH.TITLE') }}
          </span>
          <p class="mb-0 text-sm text-n-slate-11">
            {{ t('TRIAGE_FLOWS.FORM.NO_MATCH.DESCRIPTION') }}
          </p>
        </div>

        <TextArea
          :model-value="state.definition.no_match.message || ''"
          :label="t('TRIAGE_FLOWS.FORM.NO_MATCH.MESSAGE.LABEL')"
          :placeholder="t('TRIAGE_FLOWS.FORM.NO_MATCH.MESSAGE.PLACEHOLDER')"
          :max-length="NO_MATCH_MESSAGE_MAX_LENGTH"
          show-character-count
          auto-height
          @update:model-value="updateNoMatch({ message: $event })"
        />

        <Input
          :model-value="state.definition.no_match.max_attempts"
          type="number"
          min="1"
          max="5"
          class="max-w-40"
          :label="t('TRIAGE_FLOWS.FORM.NO_MATCH.MAX_ATTEMPTS.LABEL')"
          @update:model-value="updateNoMatch({ max_attempts: $event })"
        />

        <RouteEditor
          :route="state.definition.no_match.then || {}"
          :team-options="teamOptions"
          :label-options="labelOptions"
          @update="updateNoMatch({ then: $event })"
        />
      </div>

      <div class="flex flex-col gap-4 pt-6 border-t border-n-weak">
        <div class="flex items-start justify-between gap-4">
          <div class="flex flex-col gap-1">
            <span class="text-sm font-medium text-n-slate-12">
              {{ t('TRIAGE_FLOWS.FORM.TIMEOUT.TITLE') }}
            </span>
            <p class="mb-0 text-sm text-n-slate-11">
              {{ t('TRIAGE_FLOWS.FORM.TIMEOUT.DESCRIPTION') }}
            </p>
          </div>
          <Switch
            :model-value="isTimeoutEnabled"
            class="mt-1"
            @update:model-value="handleTimeoutToggle"
          />
        </div>

        <template v-if="isTimeoutEnabled">
          <Input
            :model-value="state.definition.timeout.minutes"
            type="number"
            min="1"
            max="1440"
            class="max-w-40"
            :label="t('TRIAGE_FLOWS.FORM.TIMEOUT.MINUTES.LABEL')"
            @update:model-value="updateTimeout({ minutes: $event })"
          />

          <RouteEditor
            :route="state.definition.timeout.then || {}"
            :team-options="teamOptions"
            :label-options="labelOptions"
            @update="updateTimeout({ then: $event })"
          />
        </template>
      </div>

      <Button
        type="submit"
        class="w-fit"
        :label="submitLabel"
        :disabled="isSubmitDisabled"
        :is-loading="isLoading"
      />
    </div>

    <aside class="flex flex-col gap-3 xl:sticky xl:top-4 xl:self-start">
      <span class="text-sm font-medium text-n-slate-12">
        {{ t('TRIAGE_FLOWS.FORM.PREVIEW.TITLE') }}
      </span>
      <ChannelPreview
        :definition="state.definition"
        :channel-type="channelType"
      />
    </aside>
  </form>
</template>
