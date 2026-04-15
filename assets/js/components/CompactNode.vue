<script setup>
import { Handle, Position } from "@vue-flow/core"

const props = defineProps({
  data: { type: Object, required: true },
})

const TYPE_COLORS = {
  call: { header: "#7c3aed", border: "#8b5cf6" },
  external: { header: "#6b7280", border: "#9ca3af" },
}

const colors = TYPE_COLORS[props.data.nodeType] ?? TYPE_COLORS.external
</script>

<template>
  <div class="compact-node" :style="{ borderColor: colors.border, background: colors.header + '15' }">
    <Handle type="target" :position="Position.Top" />
    <span class="compact-label" :style="{ color: colors.header }">{{ data.label }}</span>
    <Handle type="source" :position="Position.Bottom" />
  </div>
</template>
