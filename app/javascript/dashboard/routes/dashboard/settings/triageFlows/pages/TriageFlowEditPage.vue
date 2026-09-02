<script setup>
import { computed, ref, watch } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRoute, useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Breadcrumb from 'dashboard/components-next/breadcrumb/Breadcrumb.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import TriageFlowForm from '../components/TriageFlowForm.vue';

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const router = useRouter();

const uiFlags = useMapGetter('triageFlows/getUIFlags');
const flowById = useMapGetter('triageFlows/getTriageFlowById');

const serverErrors = ref([]);

const routeId = computed(() => route.params.id);
const flow = computed(() => flowById.value(routeId.value) || {});

const breadcrumbItems = computed(() => [
  {
    label: t('TRIAGE_FLOWS.INDEX.HEADER.TITLE'),
    routeName: 'triage_flows_index',
  },
  { label: flow.value.name || t('TRIAGE_FLOWS.EDIT.HEADER.TITLE') },
]);

const initialData = computed(() => ({
  name: flow.value.name || '',
  inboxId: flow.value.inbox?.id ?? '',
  channelType:
    flow.value.inbox?.channelType || flow.value.inbox?.channel_type || '',
  enabled: Boolean(flow.value.enabled),
  mode: flow.value.mode || 'shadow',
  definition: flow.value.definition || null,
}));

const handleBreadcrumbClick = ({ routeName }) =>
  router.push({ name: routeName });

const handleSubmit = async formState => {
  serverErrors.value = [];
  try {
    await store.dispatch('triageFlows/update', {
      id: flow.value.id,
      name: formState.name,
      enabled: formState.enabled,
      mode: formState.mode,
      definition: formState.definition,
    });
    useAlert(t('TRIAGE_FLOWS.EDIT.API.SUCCESS_MESSAGE'));
  } catch (error) {
    serverErrors.value = error?.definitionErrors || [];
    useAlert(t('TRIAGE_FLOWS.EDIT.API.ERROR_MESSAGE'));
  }
};

watch(
  routeId,
  id => {
    if (!flow.value.id) store.dispatch('triageFlows/show', id);
  },
  { immediate: true }
);
</script>

<template>
  <SettingsLayout :is-loading="uiFlags.isFetchingItem">
    <template #header>
      <div class="flex items-center justify-between w-full gap-2">
        <Breadcrumb :items="breadcrumbItems" @click="handleBreadcrumbClick" />
        <span v-if="flow.version" class="text-sm text-n-slate-11">
          {{ t('TRIAGE_FLOWS.EDIT.VERSION', { version: flow.version }) }}
        </span>
      </div>
    </template>

    <template #body>
      <TriageFlowForm
        :key="routeId"
        form-mode="EDIT"
        :initial-data="initialData"
        :is-loading="uiFlags.isUpdating"
        :server-errors="serverErrors"
        @submit="handleSubmit"
      />
    </template>
  </SettingsLayout>
</template>
