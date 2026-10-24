<template>
  <section id="debug" class="apl-group">
    <h2 class="apl-group-title">{{ t("apl.ui.debug") }}</h2>
    <div class="apl-group-frame">
      <ToggleRow
        :label="t('apl.ui.debugLogging')"
        :description="t('apl.ui.debugLogging.desc')"
        :enabled="debugEnabled"
        @toggle="$emit('toggle')"
      />
    </div>
  </section>
</template>

<script setup>
import ToggleRow from "./ToggleRow.vue"

defineProps({
  t: { type: Function, required: true },
  debugEnabled: { type: Boolean, default: false },
})
defineEmits(["toggle"])
</script>
