<template>
  <section id="music" class="apl-group">
    <h2 class="apl-group-title">{{ t("apl.ui.music") }}</h2>
    <div class="apl-group-frame">
      <ToggleRow
        :label="t('apl.modules.music')"
        :description="t('apl.modules.music.desc')"
        :enabled="moduleState.music"
        @toggle="$emit('toggle', 'music')"
      />

      <template v-if="mode === 'expert'">
        <SliderRow
          v-for="field in fields"
          :key="field.path"
          :label="t(field.label)"
          :hint="field.hint ? t(field.hint) : ''"
          :min="field.min"
          :max="field.max"
          :step="field.step"
          :value="getVal(field.file, field.path)"
          @update="setVal(field.file, field.path, $event)"
        />
      </template>
    </div>
  </section>
</template>

<script setup>
import SliderRow from "./SliderRow.vue"
import ToggleRow from "./ToggleRow.vue"

defineProps({
  t: { type: Function, required: true },
  mode: { type: String, required: true },
  moduleState: { type: Object, required: true },
  fields: { type: Array, required: true },
  getVal: { type: Function, required: true },
  setVal: { type: Function, required: true },
})
defineEmits(["toggle"])
</script>
