<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';
import Input from 'dashboard/components-next/input/Input.vue';
import RouteEditor from './RouteEditor.vue';

import {
  slugify,
  titleLength as countCharacters,
  uniqueId,
} from '../helpers/definition';

const props = defineProps({
  option: { type: Object, required: true },
  position: { type: Number, required: true },
  stepId: { type: String, required: true },
  steps: { type: Array, default: () => [] },
  teamOptions: { type: Array, default: () => [] },
  labelOptions: { type: Array, default: () => [] },
  titleMaxLength: { type: Number, default: 0 },
  siblingIds: { type: Array, default: () => [] },
  errors: { type: Array, default: () => [] },
});

const emit = defineEmits(['update', 'delete', 'createStep']);

const { t } = useI18n();

const NEW_STEP_VALUE = '__new_step__';
const ROUTE_VALUE = 'route';
const STEP_PREFIX = 'step:';

const emptyRoute = () => ({
  type: 'route',
  team_id: null,
  labels: [],
  status: 'open',
});

const isRoute = computed(() => props.option.next?.type === 'route');

// Counted in codepoints, the way Ruby's String#length does, so the badge here
// agrees with the channel cap the API enforces.
const titleLength = computed(() => countCharacters(props.option.title));

const isOverTitleLimit = computed(
  () => props.titleMaxLength > 0 && titleLength.value > props.titleMaxLength
);

const thenValue = computed(() => {
  const { next } = props.option;
  if (next?.type === 'step' && next.step_id) {
    return `${STEP_PREFIX}${next.step_id}`;
  }
  return next?.type === 'route' ? ROUTE_VALUE : '';
});

const thenChoices = computed(() => [
  { value: ROUTE_VALUE, label: t('TRIAGE_FLOWS.OPTION.THEN.ROUTE') },
  ...props.steps
    .filter(step => step.id !== props.stepId)
    .map(step => ({
      value: `${STEP_PREFIX}${step.id}`,
      label: t('TRIAGE_FLOWS.OPTION.THEN.GO_TO_STEP', {
        step: step.prompt || step.id,
      }),
    })),
  { value: NEW_STEP_VALUE, label: t('TRIAGE_FLOWS.OPTION.THEN.NEW_STEP') },
]);

const patch = changes => emit('update', { ...props.option, ...changes });

const handleThenUpdate = value => {
  if (value === NEW_STEP_VALUE) {
    emit('createStep');
  } else if (value === ROUTE_VALUE) {
    patch({ next: emptyRoute() });
  } else {
    patch({ next: { type: 'step', step_id: value.slice(STEP_PREFIX.length) } });
  }
};

// The id is what the customer's reply is matched against, so it is derived
// once from the first title the option is given and never touched again — a
// later rename must not silently repoint an id an open session is waiting on.
const handleTitleBlur = () => {
  if (props.option.id || !props.option.title) return;
  patch({ id: uniqueId(slugify(props.option.title), props.siblingIds) });
};
</script>

<template>
  <div
    class="flex flex-col gap-3 p-3 border rounded-xl border-n-weak bg-n-solid-2"
  >
    <div class="flex items-start gap-2">
      <span
        class="flex items-center gap-1 mt-2 option-drag-handle cursor-grab text-n-slate-10"
        :title="t('TRIAGE_FLOWS.OPTION.DRAG_HANDLE')"
      >
        <Icon icon="i-lucide-grip-vertical" class="size-4" />
        <span class="text-xs tabular-nums">{{ position }}</span>
      </span>

      <div class="flex flex-col flex-1 min-w-0 gap-1">
        <Input
          :model-value="option.title"
          :placeholder="t('TRIAGE_FLOWS.OPTION.TITLE.PLACEHOLDER')"
          :message-type="isOverTitleLimit ? 'error' : 'info'"
          @update:model-value="patch({ title: $event })"
          @blur="handleTitleBlur"
        />
        <div class="flex items-center gap-2">
          <span v-if="option.id" class="text-xs truncate text-n-slate-10">
            {{ t('TRIAGE_FLOWS.OPTION.ID_HINT', { id: option.id }) }}
          </span>
          <span
            v-if="titleMaxLength"
            class="ml-auto text-xs tabular-nums shrink-0"
            :class="isOverTitleLimit ? 'text-n-ruby-11' : 'text-n-slate-10'"
          >
            {{
              t('TRIAGE_FLOWS.OPTION.TITLE.COUNTER', {
                count: titleLength,
                max: titleMaxLength,
              })
            }}
          </span>
        </div>
      </div>

      <Button
        type="button"
        icon="i-lucide-trash-2"
        size="sm"
        color="ruby"
        variant="ghost"
        class="mt-1"
        :title="t('TRIAGE_FLOWS.OPTION.DELETE')"
        @click="emit('delete')"
      />
    </div>

    <div class="flex flex-col gap-1">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('TRIAGE_FLOWS.OPTION.THEN.LABEL') }}
      </label>
      <ComboBox
        :model-value="thenValue"
        :options="thenChoices"
        :placeholder="t('TRIAGE_FLOWS.OPTION.THEN.PLACEHOLDER')"
        :search-placeholder="t('TRIAGE_FLOWS.OPTION.THEN.SEARCH_PLACEHOLDER')"
        @update:model-value="handleThenUpdate"
      />
    </div>

    <RouteEditor
      v-if="isRoute"
      :route="option.next"
      :team-options="teamOptions"
      :label-options="labelOptions"
      @update="patch({ next: $event })"
    />

    <ul v-if="errors.length" class="flex flex-col gap-1 mb-0 list-none">
      <li v-for="error in errors" :key="error" class="text-xs text-n-ruby-11">
        {{ error }}
      </li>
    </ul>
  </div>
</template>
