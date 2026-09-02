<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import Draggable from 'vuedraggable';

import Button from 'dashboard/components-next/button/Button.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';
import OptionRow from './OptionRow.vue';

import { limitsFor, maxOptionsFor } from '../helpers/definition';

const props = defineProps({
  step: { type: Object, required: true },
  position: { type: Number, required: true },
  steps: { type: Array, default: () => [] },
  teamOptions: { type: Array, default: () => [] },
  labelOptions: { type: Array, default: () => [] },
  channelType: { type: String, default: '' },
  isEntry: { type: Boolean, default: false },
  errors: { type: Object, default: () => ({}) },
  // Non-blocking notices: a question nothing leads to is still saveable.
  warnings: { type: Array, default: () => [] },
});

const emit = defineEmits(['update', 'delete', 'addOption', 'createStep']);

const { t } = useI18n();

const PROMPT_MAX_LENGTH = 1024;

// Mirrors TriageFlows::DefinitionValidator#bounds_for: WhatsApp renders up to
// three options as reply buttons (tighter title cap) and more as a list, so
// the cap depends on how many options this step currently has. Channels with
// no menu support report Infinity, which the template reads as "no counter".
const limits = computed(() =>
  limitsFor(props.channelType, (props.step.options || []).length)
);

const capOrZero = value => (Number.isFinite(value) ? value : 0);

// The ceiling for the Add button is what the channel can render at all, not
// what it renders today: WhatsApp shows three options as buttons and up to ten
// as a list, so stopping at three would refuse a menu the API saves happily.
const maxOptions = computed(() => capOrZero(maxOptionsFor(props.channelType)));
const titleMaxLength = computed(() => capOrZero(limits.value.maxTitle));

const isAtOptionLimit = computed(
  () => maxOptions.value > 0 && props.step.options.length >= maxOptions.value
);

// Crossing from buttons to a list is not a failure, but it changes what the
// contact sees and how long a title may be, so it is worth saying out loud.
const isAtRenderModeEdge = computed(
  () =>
    !isAtOptionLimit.value &&
    limits.value.renderMode === 'buttons' &&
    props.step.options.length === capOrZero(limits.value.maxOptions)
);

const stepMessages = computed(() => props.errors.messages || []);
const optionErrors = computed(() => props.errors.options || {});

const patch = changes => emit('update', { ...props.step, ...changes });

const handleOptionsUpdate = options => patch({ options });

const handleOptionUpdate = (index, option) =>
  handleOptionsUpdate(
    props.step.options.map((current, i) => (i === index ? option : current))
  );

const handleOptionDelete = index =>
  handleOptionsUpdate(props.step.options.filter((current, i) => i !== index));

// Two options in one step cannot share an id, so a newly named option gets the
// ids already spoken for and suffixes its own.
const siblingIdsExcept = index =>
  props.step.options
    .filter((current, i) => i !== index)
    .map(current => current.id)
    .filter(Boolean);
</script>

<template>
  <div
    class="flex flex-col gap-4 p-4 border rounded-2xl border-n-container bg-n-solid-2"
  >
    <div class="flex items-center justify-between gap-3">
      <div class="flex items-center min-w-0 gap-2">
        <span class="text-sm font-medium text-n-slate-12">
          {{ t('TRIAGE_FLOWS.STEPS.STEP_LABEL', { index: position }) }}
        </span>
        <span
          v-if="isEntry"
          class="px-2 py-0.5 text-xs rounded-md bg-n-brand/10 text-n-blue-text"
        >
          {{ t('TRIAGE_FLOWS.STEPS.ENTRY_BADGE') }}
        </span>
        <span
          v-if="step.id"
          class="px-2 py-0.5 text-xs truncate rounded-md bg-n-alpha-2 text-n-slate-11"
        >
          {{ step.id }}
        </span>
      </div>
      <Button
        v-if="!isEntry"
        type="button"
        icon="i-lucide-trash-2"
        size="sm"
        color="ruby"
        variant="ghost"
        :title="t('TRIAGE_FLOWS.STEPS.DELETE_STEP')"
        @click="emit('delete')"
      />
    </div>

    <p
      v-for="warning in warnings"
      :key="warning"
      class="mb-0 text-xs text-n-amber-11"
    >
      {{ warning }}
    </p>

    <TextArea
      :model-value="step.prompt || ''"
      :label="t('TRIAGE_FLOWS.STEPS.PROMPT.LABEL')"
      :placeholder="t('TRIAGE_FLOWS.STEPS.PROMPT.PLACEHOLDER')"
      :max-length="PROMPT_MAX_LENGTH"
      show-character-count
      auto-height
      @update:model-value="patch({ prompt: $event })"
    />

    <div class="flex flex-col gap-3">
      <span class="text-sm font-medium text-n-slate-12">
        {{ t('TRIAGE_FLOWS.STEPS.OPTIONS.LABEL') }}
      </span>

      <p v-if="!step.options.length" class="mb-0 text-sm text-n-slate-11">
        {{ t('TRIAGE_FLOWS.STEPS.OPTIONS.EMPTY') }}
      </p>

      <Draggable
        :model-value="step.options"
        item-key="clientKey"
        tag="div"
        handle=".option-drag-handle"
        class="flex flex-col gap-3"
        @update:model-value="handleOptionsUpdate"
      >
        <template #item="{ element, index }">
          <OptionRow
            :option="element"
            :position="index + 1"
            :step-id="step.id"
            :steps="steps"
            :team-options="teamOptions"
            :label-options="labelOptions"
            :title-max-length="titleMaxLength"
            :sibling-ids="siblingIdsExcept(index)"
            :errors="optionErrors[element.id || String(index)] || []"
            @update="handleOptionUpdate(index, $event)"
            @delete="handleOptionDelete(index)"
            @create-step="emit('createStep', element.clientKey)"
          />
        </template>
      </Draggable>

      <div class="flex items-center gap-3">
        <Button
          type="button"
          icon="i-lucide-plus"
          size="sm"
          color="slate"
          variant="faded"
          :label="t('TRIAGE_FLOWS.STEPS.OPTIONS.ADD')"
          :disabled="isAtOptionLimit"
          @click="emit('addOption')"
        />
        <span v-if="isAtOptionLimit" class="text-xs text-n-slate-11">
          {{
            t('TRIAGE_FLOWS.STEPS.OPTIONS.LIMIT_REACHED', { max: maxOptions })
          }}
        </span>
        <span v-else-if="isAtRenderModeEdge" class="text-xs text-n-slate-11">
          {{
            t('TRIAGE_FLOWS.STEPS.OPTIONS.LIST_SWITCH', {
              max: limits.maxTitle,
            })
          }}
        </span>
      </div>
    </div>

    <ul v-if="stepMessages.length" class="flex flex-col gap-1 mb-0 list-none">
      <li
        v-for="message in stepMessages"
        :key="message"
        class="text-xs text-n-ruby-11"
      >
        {{ message }}
      </li>
    </ul>
  </div>
</template>
