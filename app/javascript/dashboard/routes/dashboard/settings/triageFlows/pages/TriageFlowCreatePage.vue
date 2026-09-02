<script setup>
import { computed, onMounted, ref } from 'vue';
import { useI18n } from 'vue-i18n';
import { useRouter } from 'vue-router';
import { useStore, useMapGetter } from 'dashboard/composables/store';
import { useAlert } from 'dashboard/composables';

import Breadcrumb from 'dashboard/components-next/breadcrumb/Breadcrumb.vue';
import SettingsLayout from 'dashboard/routes/dashboard/settings/SettingsLayout.vue';
import TriageFlowForm from '../components/TriageFlowForm.vue';

const { t } = useI18n();
const store = useStore();
const router = useRouter();

const uiFlags = useMapGetter('triageFlows/getUIFlags');

const serverErrors = ref([]);

const breadcrumbItems = computed(() => [
  {
    label: t('TRIAGE_FLOWS.INDEX.HEADER.TITLE'),
    routeName: 'triage_flows_index',
  },
  { label: t('TRIAGE_FLOWS.CREATE.HEADER.TITLE') },
]);

const handleBreadcrumbClick = ({ routeName }) =>
  router.push({ name: routeName });

const handleSubmit = async formState => {
  serverErrors.value = [];
  try {
    const flow = await store.dispatch('triageFlows/create', formState);
    useAlert(t('TRIAGE_FLOWS.CREATE.API.SUCCESS_MESSAGE'));
    router.push({ name: 'triage_flows_edit', params: { id: flow.id } });
  } catch (error) {
    serverErrors.value = error?.definitionErrors || [];
    useAlert(t('TRIAGE_FLOWS.CREATE.API.ERROR_MESSAGE'));
  }
};

onMounted(() => {
  store.dispatch('triageFlows/get');
});
</script>

<template>
  <SettingsLayout>
    <template #header>
      <Breadcrumb :items="breadcrumbItems" @click="handleBreadcrumbClick" />
    </template>

    <template #body>
      <TriageFlowForm
        form-mode="CREATE"
        :is-loading="uiFlags.isCreating"
        :server-errors="serverErrors"
        @submit="handleSubmit"
      />
    </template>
  </SettingsLayout>
</template>
