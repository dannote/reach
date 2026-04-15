<script setup>
import { ref, onMounted, nextTick, computed, watch } from "vue"
import { VueFlow, useVueFlow } from "@vue-flow/core"
import { MiniMap } from "@vue-flow/minimap"
import { Controls } from "@vue-flow/controls"
import CodeNode from "@reach/components/CodeNode.vue"
import CompactNode from "@reach/components/CompactNode.vue"
import { computeLayout } from "@reach/layout"

const props = defineProps({
  graphData: { type: Object, required: true },
})

const EDGE_TYPES = {
  data: { color: "#16a34a", label: "Data flow" },
  control: { color: "#ea580c", label: "Control" },
  containment: { color: "#94a3b8", label: "Contains" },
  call: { color: "#7c3aed", label: "Call" },
  match_binding: { color: "#16a34a", label: "Match bind" },
  state_read: { color: "#0891b2", label: "State read" },
  state_pass: { color: "#0891b2", label: "State pass" },
  higher_order: { color: "#db2777", label: "Higher order" },
  message_order: { color: "#ca8a04", label: "Message" },
  summary: { color: "#7c3aed", label: "Summary" },
}

const nodeTypes = { code: CodeNode, compact: CompactNode }
const mode = ref("control_flow")
const nodes = ref([])
const edges = ref([])
const selectedModule = ref(null)
const selectedFunction = ref(null)
const { fitView, setCenter } = useVueFlow()

function edgeStyle(edgeType) {
  const color = EDGE_TYPES[edgeType]?.color ?? "#94a3b8"
  return { stroke: color, strokeWidth: edgeType === "containment" ? 1 : 2 }
}

function estimateSize(data) {
  const lineCount = data.lines?.length ?? 1
  const codeMaxLen = (data.lines ?? []).reduce((m, l) => Math.max(m, l.length), 0)
  const labelLen = (data.label ?? "").length
  const maxLen = Math.max(codeMaxLen, labelLen)
  return {
    width: Math.min(600, Math.max(180, maxLen * 7.5 + 60)),
    height: Math.max(40, lineCount * 18 + 30),
  }
}

async function applyLayout(rawNodes, rawEdges, layoutOverrides = {}) {
  const nodeIds = rawNodes.map((n) => n.id)
  const nodeSizes = new Map()
  for (const n of rawNodes) {
    nodeSizes.set(n.id, estimateSize(n.data))
  }

  const nodeIdSet = new Set(nodeIds)
  const validEdges = rawEdges.filter((e) => nodeIdSet.has(e.source) && nodeIdSet.has(e.target))

  const positions = await computeLayout(
    nodeIds,
    nodeSizes,
    validEdges.map((e) => ({ id: e.id, source: e.source, target: e.target })),
    layoutOverrides
  )

  for (const n of rawNodes) {
    const pos = positions.get(n.id)
    if (pos) n.position = pos
  }

  nodes.value = rawNodes
  edges.value = validEdges
  await nextTick()
  fitView({ padding: 0.1 })
}

function makeCodeNode(id, label, nodeType, block) {
  const lines = block.source_html ? block.source_html.split("\n") : (block.lines ?? [])
  return {
    id,
    type: "code",
    position: { x: 0, y: 0 },
    data: {
      label,
      nodeType,
      sourceHtml: block.source_html,
      sourceText: block.source_html ? null : block.lines?.join("\n"),
      lines,
      startLine: block.start_line,
    },
  }
}

async function buildControlFlow() {
  const cf = props.graphData.control_flow
  if (!cf?.length) return

  const allNodes = []
  const allEdges = []

  for (const mod of cf) {
    for (const func of mod.functions) {
      const blocks = func.blocks

      for (const b of blocks.blocks) {
        const label =
          b.id === func.id
            ? `${mod.module ? mod.module + "." : ""}${func.name}/${func.arity}`
            : b.label

        allNodes.push(makeCodeNode(b.id, label, b.id === func.id ? "function" : "match", b))
      }

      for (const e of blocks.edges) {
        allEdges.push({
          id: e.id,
          source: e.source,
          target: e.target,
          type: "smoothstep",
          style: { stroke: e.color, strokeWidth: 2 },
          label: e.label,
          labelStyle: { fill: e.color, fontSize: 11 },
        })
      }
    }
  }

  await applyLayout(allNodes, allEdges)
}

async function buildCallGraph() {
  const cg = props.graphData.call_graph
  if (!cg) return

  const rawNodes = []
  for (const mod of cg.modules) {
    for (const func of mod.functions) {
      // Use short label for internal functions: just name/arity
      const shortLabel = mod.file ? func.id.split(".").pop() : func.id
      rawNodes.push({
        id: func.id,
        type: "compact",
        position: { x: 0, y: 0 },
        data: { label: shortLabel, nodeType: mod.file ? "call" : "external" },
      })
    }
  }

  const rawEdges = cg.edges.map((e) => ({
    id: e.id,
    source: e.source,
    target: e.target,
    type: "smoothstep",
    style: { stroke: e.color, strokeWidth: 1.5 },
  }))

  await applyLayout(rawNodes, rawEdges, {
    "elk.direction": "RIGHT",
    "elk.aspectRatio": "1.5",
  })
}

async function buildDataFlow() {
  const df = props.graphData.data_flow
  if (!df) return

  const rawNodes = df.functions.map((f) =>
    makeCodeNode(f.id, f.module ? `${f.module}.${f.label}` : f.label, "data", {
      source_html: f.source_html,
      lines: f.source_html ? null : [],
      start_line: f.start_line,
    })
  )

  const rawEdges = df.edges.map((e) => ({
    id: e.id,
    source: e.source,
    target: e.target,
    type: "smoothstep",
    style: { stroke: e.color, strokeWidth: 2 },
    label: e.label,
    labelStyle: { fill: "#16a34a", fontSize: 11 },
  }))

  await applyLayout(rawNodes, rawEdges)
}

async function rebuild() {
  try {
    switch (mode.value) {
      case "control_flow":
        await buildControlFlow()
        break
      case "call_graph":
        await buildCallGraph()
        break
      case "data_flow":
        await buildDataFlow()
        break
    }
  } catch (e) {
    console.error("rebuild error:", e)
  }
}

watch(mode, rebuild)
onMounted(rebuild)

const sidebarModules = computed(() => {
  const cf = props.graphData.control_flow
  if (!cf) return []
  return cf.map((m) => ({
    name: m.module ?? "(top-level)",
    module: m.module,
    functions: m.functions.map((f) => ({ id: f.id, label: `${f.name}/${f.arity}` })),
  }))
})

function onNodeDoubleClick(event) {
  const node = event.node
  if (mode.value === "call_graph" && node.data?.label) {
    // Extract function name from call graph label and navigate to control flow
    const label = node.data.label
    const funcName = label.split("/")[0]
    const cf = props.graphData.control_flow
    for (const mod of cf) {
      const func = mod.functions.find((f) => f.name === funcName)
      if (func) {
        selectFunction(mod.module, func.id)
        return
      }
    }
  }
}

function selectFunction(modName, funcId) {
  selectedModule.value = modName
  selectedFunction.value = funcId
  if (mode.value !== "control_flow") {
    mode.value = "control_flow"
  } else {
    const node = nodes.value.find((n) => n.id === funcId)
    if (node?.position) {
      setCenter(node.position.x + 200, node.position.y + 50, { zoom: 1, duration: 300 })
    }
  }
}
</script>

<template>
  <div class="reach-container">
    <div class="tab-bar">
      <div class="tab-bar-tabs">
        <button class="tab" :class="{ active: mode === 'control_flow' }" @click="mode = 'control_flow'">
          Control Flow
        </button>
        <button class="tab" :class="{ active: mode === 'call_graph' }" @click="mode = 'call_graph'">
          Call Graph
        </button>
        <button class="tab" :class="{ active: mode === 'data_flow' }" @click="mode = 'data_flow'">
          Data Flow
        </button>
      </div>
    </div>

    <div class="main-area">
      <div v-if="mode === 'control_flow'" class="sidebar">
        <div class="sidebar-title">Functions</div>
        <div v-for="mod in sidebarModules" :key="mod.name" class="sidebar-module">
          <div class="sidebar-module-name">{{ mod.name }}</div>
          <button
            v-for="func in mod.functions"
            :key="func.id"
            class="sidebar-func"
            :class="{ active: selectedFunction === func.id }"
            @click="selectFunction(mod.module, func.id)"
          >
            {{ func.label }}
          </button>
        </div>
      </div>

      <VueFlow
        :nodes="nodes"
        :edges="edges"
        :node-types="nodeTypes"
        :default-edge-options="{ type: 'smoothstep' }"
        :min-zoom="0.1"
        :max-zoom="3"
        class="reach-flow"
        @node-double-click="onNodeDoubleClick"
      >
        <MiniMap pannable zoomable />
        <Controls />
      </VueFlow>
    </div>
  </div>
</template>
