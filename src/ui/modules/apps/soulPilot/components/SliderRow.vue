<template>
  <div class="apl-row">
    <div class="apl-row-label">
      <span>{{ label }}</span>
      <small v-if="hint">{{ hint }}</small>
    </div>
    <div class="apl-slider-cell">
      <input
        class="apl-range"
        type="range"
        :min="min"
        :max="max"
        :step="step"
        :value="value"
        @input="$emit('update', Number($event.target.value))"
      />
      <input
        class="apl-number"
        type="number"
        :min="min"
        :max="max"
        :step="step"
        :value="value"
        @change="$emit('update', Number($event.target.value))"
      />
    </div>
  </div>
</template>

<script setup>
defineProps({
  label: { type: String, required: true },
  hint: { type: String, default: "" },
  min: { type: Number, required: true },
  max: { type: Number, required: true },
  step: { type: Number, required: true },
  value: { type: Number, default: 0 },
})
defineEmits(["update"])
</script>
