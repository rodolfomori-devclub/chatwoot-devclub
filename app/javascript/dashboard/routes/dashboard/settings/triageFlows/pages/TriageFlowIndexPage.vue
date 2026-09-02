<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';
import {
  getInboxIconByType,
  getReadableInboxByType,
} from 'dashboard/helper/inbox';

import BaseSettingsHeader from 'dashboard/routes/dashboard/settings/components/BaseSettingsHeader.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import Button from 'dashboard/components-next/button/Button.vue';
import CardLayout from 'dashboard/components-next/CardLayout.vue';
import ComboBox from 'dashboard/components-next/combobox/ComboBox.vue';
import Dialog from 'dashboard/components-next/dialog/Dialog.vue';
import EmptyStateLayout from 'dashboard/components-next/EmptyStateLayout.vue';
import Icon from 'dashboard/components-next/icon/Icon.vue';

const { t } = useI18n();
const store = useStore();
const router = useRouter();

const flows = useMapGetter('triageFlows/getTriageFlows');
const uiFlags = useMapGetter('triageFlows/getUIFlags');
const inboxes = useMapGetter('inboxes/getInboxes');

const deleteDialogRef = ref(null);
const cloneDialogRef = ref(null);
const activeFlowId = ref(null);
const cloneInboxId = ref('');

const channelTypeOf = inbox => inbox?.channelType || inbox?.channel_type || '';

const inboxTypeLabel = channelType => getReadableInboxByType(channelType, '');

const badgeFor = flow => {
  if (!flow.enabled) {
    return {
      label: t('TRIAGE_FLOWS.STATUS.OFF'),
      class: 'bg-n-alpha-2 text-n-slate-11',
    };
  }
  if (flow.mode === 'live') {
    return {
      label: t('TRIAGE_FLOWS.STATUS.LIVE'),
      class: 'bg-n-teal-9/10 text-n-teal-11',
    };
  }
  return {
    label: t('TRIAGE_FLOWS.STATUS.SHADOW'),
    class: 'bg-n-amber-9/10 text-n-amber-11',
  };
};

// The API reports what is wrong with a saved flow, not just how much: a step
// nothing leads to, or a route still pointing at a deleted team. A count alone
// leaves the team opening flows to find out which.
const WARNING_KEYS = {
  unreachable_step: 'TRIAGE_FLOWS.INDEX.WARNINGS.UNREACHABLE_STEP',
  missing_team: 'TRIAGE_FLOWS.INDEX.WARNINGS.MISSING_TEAM',
};

const warningsFor = flow =>
  (flow.warnings || [])
    .filter(warning => WARNING_KEYS[warning.type])
    .map(warning =>
      t(WARNING_KEYS[warning.type], {
        stepId: warning.stepId,
        teamId: warning.teamId,
      })
    );

const rows = computed(() =>
  flows.value.map(flow => ({
    id: flow.id,
    name: flow.name,
    inboxName: flow.inbox?.name || '',
    icon: getInboxIconByType(channelTypeOf(flow.inbox), '', 'line'),
    badge: badgeFor(flow),
    stepCount: flow.definition?.steps?.length || 0,
    warningCount: flow.warnings?.length || 0,
    warnings: warningsFor(flow),
  }))
);

const usedInboxIds = computed(
  () => new Set(flows.value.map(flow => flow.inbox?.id))
);

// A clone onto a channel with tighter caps is refused by the API, and a list of
// bare names gives no way to see that coming.
const availableInboxOptions = computed(() =>
  inboxes.value
    .filter(inbox => !usedInboxIds.value.has(inbox.id))
    .map(inbox => ({
      value: inbox.id,
      label: `${inbox.name} · ${inboxTypeLabel(channelTypeOf(inbox))}`,
    }))
);

const goToCreate = () => router.push({ name: 'triage_flows_new' });

const goToEdit = id =>
  router.push({ name: 'triage_flows_edit', params: { id } });

const openDeleteDialog = id => {
  activeFlowId.value = id;
  deleteDialogRef.value.open();
};

const openCloneDialog = id => {
  activeFlowId.value = id;
  cloneInboxId.value = '';
  cloneDialogRef.value.open();
};

const handleDelete = async () => {
  try {
    await store.dispatch('triageFlows/delete', activeFlowId.value);
    useAlert(t('TRIAGE_FLOWS.DELETE.API.SUCCESS_MESSAGE'));
    deleteDialogRef.value.close();
  } catch (error) {
    // The API says why it refused — the target inbox already has a flow, or a
    // title is too long for the channel being cloned onto. There is no inline
    // surface in a dialog, so the toast has to carry it.
    useAlert(error.message || t('TRIAGE_FLOWS.DELETE.API.ERROR_MESSAGE'));
  }
};

const handleClone = async () => {
  try {
    await store.dispatch('triageFlows/clone', {
      id: activeFlowId.value,
      inboxId: cloneInboxId.value,
    });
    useAlert(t('TRIAGE_FLOWS.CLONE.API.SUCCESS_MESSAGE'));
    cloneDialogRef.value.close();
  } catch (error) {
    // The API says why it refused — the target inbox already has a flow, or a
    // title is too long for the channel being cloned onto. There is no inline
    // surface in a dialog, so the toast has to carry it.
    useAlert(error.message || t('TRIAGE_FLOWS.CLONE.API.ERROR_MESSAGE'));
  }
};

onMounted(() => {
  store.dispatch('triageFlows/get');
  store.dispatch('inboxes/get');
});
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetching">
    <template #header>
      <BaseSettingsHeader
        :title="t('TRIAGE_FLOWS.INDEX.HEADER.TITLE')"
        :description="t('TRIAGE_FLOWS.INDEX.HEADER.DESCRIPTION')"
      >
        <template #actions>
          <Button
            v-if="rows.length"
            icon="i-lucide-plus"
            size="md"
            :label="t('TRIAGE_FLOWS.INDEX.HEADER.CREATE_FLOW')"
            @click="goToCreate"
          />
        </template>
      </BaseSettingsHeader>
    </template>

    <template #body>
      <EmptyStateLayout
        v-if="!rows.length"
        :title="t('TRIAGE_FLOWS.INDEX.EMPTY_STATE.TITLE')"
        :subtitle="t('TRIAGE_FLOWS.INDEX.EMPTY_STATE.SUBTITLE')"
        :show-backdrop="false"
      >
        <template #actions>
          <Button
            icon="i-lucide-plus"
            size="md"
            :label="t('TRIAGE_FLOWS.INDEX.EMPTY_STATE.ACTION')"
            @click="goToCreate"
          />
        </template>
      </EmptyStateLayout>

      <div v-else class="flex flex-col gap-4">
        <CardLayout v-for="row in rows" :key="row.id" layout="row">
          <div class="flex flex-col min-w-0 gap-1">
            <div class="flex items-center min-w-0 gap-2">
              <Icon :icon="row.icon" class="shrink-0 size-4 text-n-slate-11" />
              <h3 class="text-base font-medium truncate text-n-slate-12">
                {{ row.inboxName }}
              </h3>
              <span
                class="px-2 py-0.5 text-xs rounded-md shrink-0"
                :class="row.badge.class"
              >
                {{ row.badge.label }}
              </span>
            </div>
            <div class="flex items-center gap-3 text-sm text-n-slate-11">
              <span class="truncate">{{ row.name }}</span>
              <span>{{
                t('TRIAGE_FLOWS.INDEX.STEP_COUNT', { count: row.stepCount })
              }}</span>
              <span v-if="row.warningCount" class="text-n-amber-11">
                {{
                  t('TRIAGE_FLOWS.INDEX.WARNING_COUNT', {
                    count: row.warningCount,
                  })
                }}
              </span>
            </div>
            <ul
              v-if="row.warnings.length"
              class="flex flex-col mb-0 list-none gap-0.5"
            >
              <li
                v-for="warning in row.warnings"
                :key="warning"
                class="text-xs text-n-amber-11"
              >
                {{ warning }}
              </li>
            </ul>
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <Button
              size="sm"
              color="slate"
              variant="link"
              class="px-2"
              :label="t('TRIAGE_FLOWS.INDEX.EDIT')"
              @click="goToEdit(row.id)"
            />
            <div class="w-px h-2.5 bg-n-slate-5" />
            <Button
              icon="i-lucide-copy"
              size="sm"
              color="slate"
              variant="ghost"
              :title="t('TRIAGE_FLOWS.INDEX.CLONE')"
              @click="openCloneDialog(row.id)"
            />
            <Button
              icon="i-lucide-trash-2"
              size="sm"
              color="ruby"
              variant="ghost"
              :title="t('TRIAGE_FLOWS.INDEX.DELETE')"
              @click="openDeleteDialog(row.id)"
            />
          </div>
        </CardLayout>
      </div>
    </template>

    <Dialog
      ref="deleteDialogRef"
      type="alert"
      :title="t('TRIAGE_FLOWS.DELETE.TITLE')"
      :description="t('TRIAGE_FLOWS.DELETE.DESCRIPTION')"
      :confirm-button-label="t('TRIAGE_FLOWS.DELETE.CONFIRM')"
      :cancel-button-label="t('TRIAGE_FLOWS.DELETE.CANCEL')"
      :is-loading="uiFlags.isDeleting"
      @confirm="handleDelete"
    />

    <Dialog
      ref="cloneDialogRef"
      :title="t('TRIAGE_FLOWS.CLONE.TITLE')"
      :description="t('TRIAGE_FLOWS.CLONE.DESCRIPTION')"
      :confirm-button-label="t('TRIAGE_FLOWS.CLONE.CONFIRM')"
      :cancel-button-label="t('TRIAGE_FLOWS.CLONE.CANCEL')"
      :disable-confirm-button="!cloneInboxId"
      :is-loading="uiFlags.isCloning"
      @confirm="handleClone"
    >
      <div class="flex flex-col gap-1">
        <label class="text-sm font-medium text-n-slate-12">
          {{ t('TRIAGE_FLOWS.CLONE.INBOX_LABEL') }}
        </label>
        <ComboBox
          v-model="cloneInboxId"
          :options="availableInboxOptions"
          :placeholder="t('TRIAGE_FLOWS.CLONE.INBOX_PLACEHOLDER')"
          :search-placeholder="t('TRIAGE_FLOWS.CLONE.INBOX_SEARCH_PLACEHOLDER')"
          :empty-state="t('TRIAGE_FLOWS.CLONE.EMPTY_INBOXES')"
        />
      </div>
    </Dialog>
  </SettingsLayout>
</template>
