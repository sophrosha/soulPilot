<template>
  <section id="general" class="apl-group">
    <h2 class="apl-group-title">{{ t("apl.ui.general") }}</h2>
    <div class="apl-group-frame">
      <ToggleRow
        :label="t('apl.modules.master')"
        :description="t('apl.modules.master.desc')"
        :enabled="moduleState.master"
        @toggle="$emit('toggle', 'master')"
      />
      <ToggleRow
        :label="t('apl.modules.lights')"
        :description="t('apl.modules.lights.desc')"
        :enabled="moduleState.lights"
        @toggle="$emit('toggle', 'lights')"
      />
      <ToggleRow
        :label="t('apl.modules.music')"
        :description="t('apl.modules.music.desc')"
        :enabled="moduleState.music"
        @toggle="$emit('toggle', 'music')"
      />
    </div>
  </section>
</template>

<script setup>
import ToggleRow from "./ToggleRow.vue"

defineProps({
  t: { type: Function, required: true },
  moduleState: { type: Object, required: true },
})
defineEmits(["toggle"])
</script>
