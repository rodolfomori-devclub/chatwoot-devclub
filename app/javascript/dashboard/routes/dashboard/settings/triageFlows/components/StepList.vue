<script setup>
import { computed, ref } from 'vue';
import { useI18n } from 'vue-i18n';

import Button from 'dashboard/components-next/button/Button.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import StepCard from './StepCard.vue';

const props = defineProps({
  steps: { type: Array, required: true },
  entryStepId: { type: String, default: '' },
  teamOptions: { type: Array, default: () => [] },
  labelOptions: { type: Array, default: () => [] },
  channelType: { type: String, default: '' },
  errors: { type: Object, default: () => ({}) },
  warnings: { type: Object, default: () => ({}) },
});

const emit = defineEmits(['update', 'addStep', 'addOption', 'createStep']);

const { t } = useI18n();

// The entry step is where every conversation starts, so it is pinned first
// no matter where it sits in the stored array.
const orderedSteps = computed(() => {
  const entry = props.steps.find(step => step.id === props.entryStepId);
  const rest = props.steps.filter(step => step.id !== props.entryStepId);
  return entry ? [entry, ...rest] : rest;
});

const handleStepUpdate = updated =>
  emit(
    'update',
    props.steps.map(step => (step.id === updated.id ? updated : step))
  );

// Deleting the first question would leave the flow with no way in, so it stays.
// Every option that pointed at a deleted question loses its destination rather
// than keeping a dangling step_id the engine cannot follow — the option then
// shows "needs a destination", which is the thing the team has to decide.
const applyStepDelete = id =>
  emit(
    'update',
    props.steps
      .filter(step => step.id !== id)
      .map(step => ({
        ...step,
        options: (step.options || []).map(option =>
          option.next?.type === 'step' && option.next.step_id === id
            ? { ...option, next: null }
            : option
        ),
      }))
  );

// The trash icon sits in the card header next to the option rows and takes a
// question, its options and all their routing with it, with no undo. The count
// is spelled out because "3 options" is what makes the click reversible in the
// only place it still can be: before it happens.
const pendingDeleteId = ref('');
const deleteDialogRef = ref(null);

const pendingDeleteStep = computed(() =>
  props.steps.find(step => step.id === pendingDeleteId.value)
);

const orphanedOptionCount = computed(
  () =>
    props.steps.filter(step =>
      (step.options || []).some(
        option =>
          option.next?.type === 'step' &&
          option.next.step_id === pendingDeleteId.value
      )
    ).length
);

const deleteDescription = computed(() =>
  t('TRIAGE_FLOWS.STEPS.DELETE_DIALOG.DESCRIPTION', {
    options: (pendingDeleteStep.value?.options || []).length,
    parents: orphanedOptionCount.value,
  })
);

const handleStepDelete = id => {
  if (id === props.entryStepId) return;

  pendingDeleteId.value = id;
  deleteDialogRef.value.open();
};

const confirmStepDelete = () => {
  applyStepDelete(pendingDeleteId.value);
  pendingDeleteId.value = '';
  deleteDialogRef.value.close();
};
</script>

<template>
  <div class="flex flex-col gap-4">
    <div class="flex flex-col gap-1">
      <span class="text-sm font-medium text-n-slate-12">
        {{ t('TRIAGE_FLOWS.STEPS.TITLE') }}
      </span>
      <p class="mb-0 text-sm text-n-slate-11">
        {{ t('TRIAGE_FLOWS.STEPS.DESCRIPTION') }}
      </p>
    </div>

    <StepCard
      v-for="(step, index) in orderedSteps"
      :key="step.id"
      :step="step"
      :position="index + 1"
      :steps="steps"
      :team-options="teamOptions"
      :label-options="labelOptions"
      :channel-type="channelType"
      :is-entry="step.id === entryStepId"
      :errors="errors[step.id] || {}"
      :warnings="warnings[step.id] || []"
      @update="handleStepUpdate"
      @delete="handleStepDelete(step.id)"
      @add-option="emit('addOption', step.id)"
      @create-step="emit('createStep', { stepId: step.id, optionKey: $event })"
    />

    <Button
      type="button"
      icon="i-lucide-plus"
      size="sm"
      color="slate"
      variant="faded"
      class="w-fit"
      :label="t('TRIAGE_FLOWS.STEPS.ADD_STEP')"
      @click="emit('addStep')"
    />

    <Dialog
      ref="deleteDialogRef"
      type="alert"
      :title="t('TRIAGE_FLOWS.STEPS.DELETE_DIALOG.TITLE')"
      :description="deleteDescription"
      :confirm-button-label="t('TRIAGE_FLOWS.STEPS.DELETE_DIALOG.CONFIRM')"
      :cancel-button-label="t('TRIAGE_FLOWS.STEPS.DELETE_DIALOG.CANCEL')"
      @confirm="confirmStepDelete"
    />
  </div>
</template>
