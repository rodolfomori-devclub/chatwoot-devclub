<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';

import {
  limitsFor,
  titleLength,
} from 'dashboard/routes/dashboard/settings/triageFlows/helpers/definition';

const props = defineProps({
  definition: {
    type: Object,
    default: () => ({}),
  },
  channelType: {
    type: String,
    default: '',
  },
  activeStepId: {
    type: String,
    default: '',
  },
});

const { t } = useI18n();

const steps = computed(() =>
  Array.isArray(props.definition?.steps) ? props.definition.steps : []
);

const step = computed(() => {
  const wanted = props.activeStepId || props.definition?.entry_step_id;
  return steps.value.find(item => item.id === wanted) || steps.value[0];
});

const options = computed(() =>
  Array.isArray(step.value?.options) ? step.value.options : []
);

const limits = computed(() =>
  limitsFor(props.channelType, options.value.length)
);

const isWhatsapp = computed(() => props.channelType === 'Channel::Whatsapp');

const hasTitleCap = computed(() => Number.isFinite(limits.value.maxTitle));

// Rows carry the character budget so every render mode highlights the same way.
const rows = computed(() =>
  options.value.map((option, index) => {
    const length = titleLength(option.title);
    return {
      key: option.id || `option-${index}`,
      position: index + 1,
      title: option.title,
      length,
      isOverCap: hasTitleCap.value && length > limits.value.maxTitle,
    };
  })
);

const isOverOptionCap = computed(
  () => options.value.length > limits.value.maxOptions
);

const modeLabel = computed(() => {
  if (isWhatsapp.value) {
    return limits.value.renderMode === 'buttons'
      ? t('TRIAGE_FLOWS.PREVIEW.MODE.WHATSAPP_BUTTONS')
      : t('TRIAGE_FLOWS.PREVIEW.MODE.WHATSAPP_LIST');
  }
  return limits.value.renderMode === 'text'
    ? t('TRIAGE_FLOWS.PREVIEW.MODE.TEXT')
    : t('TRIAGE_FLOWS.PREVIEW.MODE.WIDGET');
});

const optionCounter = computed(() =>
  Number.isFinite(limits.value.maxOptions)
    ? t('TRIAGE_FLOWS.PREVIEW.OPTION_COUNT', {
        count: options.value.length,
        max: limits.value.maxOptions,
      })
    : t('TRIAGE_FLOWS.PREVIEW.OPTION_COUNT_UNCAPPED', {
        count: options.value.length,
      })
);

// Channels without input_select receive the menu as one plain text message,
// exactly as TriageFlows::PromptSender builds it.
const plainTextMessage = computed(() =>
  [
    step.value?.prompt,
    rows.value.map(row => `${row.position}. ${row.title}`).join('\n'),
  ]
    .filter(part => part)
    .join('\n\n')
);
</script>

<template>
  <div class="flex flex-col gap-2">
    <div class="flex items-center justify-between gap-2">
      <span class="text-xs font-medium text-n-slate-11">{{ modeLabel }}</span>
      <span
        class="text-xs tabular-nums"
        :class="isOverOptionCap ? 'text-n-ruby-11' : 'text-n-slate-10'"
      >
        {{ optionCounter }}
      </span>
    </div>

    <div
      v-if="!step"
      class="px-3 py-6 text-sm text-center border border-dashed rounded-lg text-n-slate-10 border-n-weak"
    >
      {{ t('TRIAGE_FLOWS.PREVIEW.EMPTY') }}
    </div>

    <div
      v-else-if="isWhatsapp"
      class="flex flex-col gap-1 p-3 rounded-lg bg-[#e5ddd5] dark:bg-[#0b141a]"
    >
      <div
        class="max-w-[17rem] px-3 py-2 text-sm whitespace-pre-line rounded-lg rounded-tl-none shadow-sm bg-white dark:bg-[#202c33] text-[#111b21] dark:text-[#e9edef]"
      >
        {{ step.prompt }}
      </div>

      <template v-if="limits.renderMode === 'buttons'">
        <div
          v-for="row in rows"
          :key="row.key"
          class="max-w-[17rem] flex items-center justify-center gap-1.5 px-3 py-2 text-sm font-medium rounded-lg shadow-sm bg-white dark:bg-[#202c33]"
          :class="row.isOverCap ? 'text-n-ruby-11' : 'text-[#00a5f4]'"
        >
          <span class="truncate">{{ row.title }}</span>
          <span
            v-if="row.isOverCap"
            class="px-1 text-xs rounded tabular-nums bg-n-ruby-3 text-n-ruby-11"
          >
            {{
              t('TRIAGE_FLOWS.PREVIEW.CHAR_COUNT', {
                count: row.length,
                max: limits.maxTitle,
              })
            }}
          </span>
        </div>
      </template>

      <template v-else>
        <div
          class="max-w-[17rem] flex items-center justify-center gap-1.5 px-3 py-2 text-sm font-medium rounded-lg shadow-sm bg-white dark:bg-[#202c33] text-[#00a5f4]"
        >
          <span class="i-lucide-list size-4" />
          {{ t('TRIAGE_FLOWS.PREVIEW.LIST_BUTTON') }}
        </div>
        <div
          class="max-w-[17rem] mt-1 overflow-hidden bg-white rounded-lg shadow-sm dark:bg-[#202c33] divide-y divide-black/5 dark:divide-white/10"
        >
          <div
            v-for="row in rows"
            :key="row.key"
            class="flex items-center justify-between gap-2 px-3 py-2 text-sm"
            :class="
              row.isOverCap
                ? 'text-n-ruby-11'
                : 'text-[#111b21] dark:text-[#e9edef]'
            "
          >
            <span class="truncate">{{ row.title }}</span>
            <span
              v-if="row.isOverCap"
              class="px-1 text-xs rounded tabular-nums bg-n-ruby-3 text-n-ruby-11"
            >
              {{
                t('TRIAGE_FLOWS.PREVIEW.CHAR_COUNT', {
                  count: row.length,
                  max: limits.maxTitle,
                })
              }}
            </span>
            <span
              v-else
              class="flex-shrink-0 border rounded-full size-4 border-black/20 dark:border-white/30"
            />
          </div>
        </div>
      </template>
    </div>

    <div
      v-else-if="limits.renderMode === 'text'"
      class="p-3 rounded-lg bg-n-slate-2 dark:bg-n-solid-2"
    >
      <div
        class="max-w-[17rem] px-3 py-2 text-sm whitespace-pre-line rounded-lg text-n-slate-12 bg-n-background dark:bg-n-solid-3"
      >
        {{ plainTextMessage }}
      </div>
    </div>

    <div v-else class="p-3 rounded-lg bg-n-slate-2 dark:bg-n-solid-2">
      <div
        class="max-w-[17rem] px-4 py-2 rounded-lg bg-n-background dark:bg-n-solid-3"
      >
        <p class="my-1 text-sm whitespace-pre-line text-n-slate-12">
          {{ step.prompt }}
        </p>
        <ul class="flex flex-wrap gap-1 py-1">
          <li
            v-for="row in rows"
            :key="row.key"
            class="flex items-center max-w-full gap-1 px-4 py-2 text-sm border rounded-full"
            :class="
              row.isOverCap
                ? 'border-n-ruby-8 text-n-ruby-11'
                : 'border-n-brand text-n-brand'
            "
          >
            <span class="truncate">{{ row.title }}</span>
            <span
              v-if="row.isOverCap"
              class="px-1 text-xs rounded tabular-nums bg-n-ruby-3 text-n-ruby-11"
            >
              {{
                t('TRIAGE_FLOWS.PREVIEW.CHAR_COUNT', {
                  count: row.length,
                  max: limits.maxTitle,
                })
              }}
            </span>
          </li>
        </ul>
      </div>
    </div>

    <p v-if="isOverOptionCap" class="text-xs text-n-ruby-11">
      {{
        t('TRIAGE_FLOWS.PREVIEW.TOO_MANY_OPTIONS', {
          count: options.length,
          max: limits.maxOptions,
        })
      }}
    </p>
    <p v-else-if="step && !options.length" class="text-xs text-n-slate-10">
      {{ t('TRIAGE_FLOWS.PREVIEW.NO_OPTIONS') }}
    </p>
  </div>
</template>
