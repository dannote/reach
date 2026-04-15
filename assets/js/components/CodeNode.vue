<script setup>
import { Handle, Position } from "@vue-flow/core"

const props = defineProps({
  data: { type: Object, required: true },
})

const TYPE_COLORS = {
  function: { header: "#16a34a", headerText: "#fff", border: "#22c55e" },
  clause: { header: "#2563eb", headerText: "#fff", border: "#3b82f6" },
  module: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
  external: { header: "#6b7280", headerText: "#fff", border: "#9ca3af" },
  match: { header: "#16a34a", headerText: "#fff", border: "#22c55e" },
  fail: { header: "#dc2626", headerText: "#fff", border: "#ef4444" },
  call: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
  data: { header: "#0891b2", headerText: "#fff", border: "#06b6d4" },
}

const colors = TYPE_COLORS[props.data.nodeType] ?? TYPE_COLORS.clause
</script>

<template>
  <div class="code-node" :style="{ borderColor: colors.border }">
    <Handle type="target" :position="Position.Top" />
    <div class="code-node-header" :style="{ background: colors.header, color: colors.headerText }">
      {{ data.label }}
    </div>
    <div v-if="data.sourceHtml" class="code-node-body highlight">
      <table class="code-table">
        <tr v-for="(line, i) in data.lines" :key="i">
          <td class="line-number">{{ data.startLine + i }}</td>
          <td class="line-code" v-html="line"></td>
        </tr>
      </table>
    </div>
    <div v-else-if="data.sourceText" class="code-node-body highlight">
      <table class="code-table">
        <tr v-for="(line, i) in data.sourceText.split('\n')" :key="i">
          <td class="line-number">{{ data.startLine + i }}</td>
          <td class="line-code"><code>{{ line }}</code></td>
        </tr>
      </table>
    </div>
    <Handle type="source" :position="Position.Bottom" />
  </div>
</template>
