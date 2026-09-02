<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import TagMultiSelectComboBox from 'dashboard/components-next/combobox/TagMultiSelectComboBox.vue';
import TextArea from 'dashboard/components-next/textarea/TextArea.vue';

const props = defineProps({
  route: { type: Object, required: true },
  teamOptions: { type: Array, default: () => [] },
  labelOptions: { type: Array, default: () => [] },
});

const emit = defineEmits(['update']);

const { t } = useI18n();

const CLOSING_MESSAGE_MAX_LENGTH = 1024;

// The API speaks conversation statuses; the support team thinks in outcomes,
// so "pending" is presented as the hand-off to the external AI bot.
const statusOptions = computed(() => [
  { value: 'open', label: t('TRIAGE_FLOWS.ROUTE.STATUS.OPEN') },
  { value: 'pending', label: t('TRIAGE_FLOWS.ROUTE.STATUS.PENDING') },
  { value: 'resolved', label: t('TRIAGE_FLOWS.ROUTE.STATUS.RESOLVED') },
]);

const teamChoices = computed(() => [
  { value: '', label: t('TRIAGE_FLOWS.ROUTE.TEAM.NONE') },
  ...props.teamOptions,
]);

const teamValue = computed(() => props.route.team_id ?? '');

// A route outlives the team it points at: the API reports that as a warning
// when the flow is read and then refuses the next save. Say so next to the
// field that has to change. An empty option list means the teams have not
// loaded yet, not that every team is gone.
const isTeamMissing = computed(
  () =>
    Boolean(props.route.team_id) &&
    props.teamOptions.length > 0 &&
    !props.teamOptions.some(option => option.value === props.route.team_id)
);

// An empty closing message means the contact taps the option and receives
// nothing at all — the placeholder reads like a default that is already there,
// which is how this becomes "o robô travou" the next morning.
const hasNoMessage = computed(() => !String(props.route.message ?? '').trim());

// The editor is also handed the bare `{}` that an empty no-match or timeout
// block starts as, so every emit re-stamps the full shape the engine reads
// rather than passing a half-built node down the wire.
const patch = changes =>
  emit('update', {
    team_id: null,
    labels: [],
    status: 'open',
    ...props.route,
    ...changes,
    type: 'route',
  });

const handleTeamUpdate = value =>
  patch({ team_id: value === '' ? null : value });
</script>

<template>
  <div class="flex flex-col gap-4 p-4 rounded-xl bg-n-solid-1">
    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2">
      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('TRIAGE_FLOWS.ROUTE.TEAM.LABEL') }}
        </label>
        <ComboBox
          :model-value="teamValue"
          :options="teamChoices"
          :placeholder="t('TRIAGE_FLOWS.ROUTE.TEAM.PLACEHOLDER')"
          :search-placeholder="t('TRIAGE_FLOWS.ROUTE.TEAM.SEARCH_PLACEHOLDER')"
          :empty-state="t('TRIAGE_FLOWS.ROUTE.TEAM.EMPTY_STATE')"
          @update:model-value="handleTeamUpdate"
        />
        <p v-if="isTeamMissing" class="mb-0 text-xs text-n-amber-11">
          {{ t('TRIAGE_FLOWS.ROUTE.TEAM.MISSING') }}
        </p>
      </div>

      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('TRIAGE_FLOWS.ROUTE.STATUS.LABEL') }}
        </label>
        <ComboBox
          :model-value="route.status || ''"
          :options="statusOptions"
          :placeholder="t('TRIAGE_FLOWS.ROUTE.STATUS.PLACEHOLDER')"
          @update:model-value="patch({ status: $event })"
        />
      </div>
    </div>

    <div class="flex flex-col gap-1">
      <label class="text-sm font-medium text-n-slate-12">
        {{ t('TRIAGE_FLOWS.ROUTE.LABELS.LABEL') }}
      </label>
      <TagMultiSelectComboBox
        :model-value="route.labels || []"
        :options="labelOptions"
        :placeholder="t('TRIAGE_FLOWS.ROUTE.LABELS.PLACEHOLDER')"
        :search-placeholder="t('TRIAGE_FLOWS.ROUTE.LABELS.SEARCH_PLACEHOLDER')"
        :empty-state="t('TRIAGE_FLOWS.ROUTE.LABELS.EMPTY_STATE')"
        @update:model-value="patch({ labels: [...$event] })"
      />
    </div>

    <TextArea
      :model-value="route.message || ''"
      :label="t('TRIAGE_FLOWS.ROUTE.MESSAGE.LABEL')"
      :placeholder="t('TRIAGE_FLOWS.ROUTE.MESSAGE.PLACEHOLDER')"
      :max-length="CLOSING_MESSAGE_MAX_LENGTH"
      show-character-count
      auto-height
      @update:model-value="patch({ message: $event })"
    />
    <p v-if="hasNoMessage" class="mb-0 -mt-2 text-xs text-n-amber-11">
      {{ t('TRIAGE_FLOWS.ROUTE.MESSAGE.SILENT') }}
    </p>
  </div>
</template>
