<template>
  <section id="steering" class="apl-group">
    <h2 class="apl-group-title">{{ t("apl.ui.steering") }}</h2>
    <div class="apl-group-frame">
      <div class="apl-row">
        <div class="apl-row-label">
          <span>{{ t("apl.ui.profile") }}</span>
          <small>{{ t("apl.modules.wheel.desc") }}</small>
        </div>
        <div class="apl-cycle">
          <button class="apl-cycle-arrow" @click="$emit('cycle-profile', -1)">‹</button>
          <span class="apl-cycle-value">{{ t(profileLabel) }}</span>
          <button class="apl-cycle-arrow" @click="$emit('cycle-profile', 1)">›</button>
        </div>
      </div>

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

defineProps({
  t: { type: Function, required: true },
  mode: { type: String, required: true },
  profileLabel: { type: String, required: true },
  fields: { type: Array, required: true },
  getVal: { type: Function, required: true },
  setVal: { type: Function, required: true },
})
defineEmits(["cycle-profile"])
</script>
