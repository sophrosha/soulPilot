<template>
  <div class="apl-row">
    <div class="apl-row-label">
      <span>{{ label }}</span>
      <small v-if="description">{{ description }}</small>
    </div>
    <button class="apl-toggle" :class="{ on: enabled }" @click="$emit('toggle')">
      <span class="apl-toggle-knob"></span>
    </button>
  </div>
</template>

<script setup>
defineProps({
  label: { type: String, required: true },
  description: { type: String, default: "" },
  enabled: { type: Boolean, default: false },
})
defineEmits(["toggle"])
</script>
