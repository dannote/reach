import { computeLayout } from "@reach/layout"
import { Controls } from "@vue-flow/controls"
import { VueFlow, useVueFlow, Handle, Position } from "@vue-flow/core"
import { MiniMap } from "@vue-flow/minimap"
import { createApp, ref, onMounted, nextTick, computed, h, watch } from "vue"

// ── Code Node ──

const TYPE_COLORS = {
  function: { header: "#16a34a", headerText: "#fff", border: "#22c55e" },
  clause: { header: "#2563eb", headerText: "#fff", border: "#3b82f6" },
  module: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
  external: { header: "#6b7280", headerText: "#fff", border: "#9ca3af" },
  match: { header: "#16a34a", headerText: "#fff", border: "#22c55e" },
  fail: { header: "#dc2626", headerText: "#fff", border: "#ef4444" },
  call: { header: "#7c3aed", headerText: "#fff", border: "#8b5cf6" },
  data: { header: "#0891b2", headerText: "#fff", border: "#06b6d4" }
}

const CodeNode = {
  props: { data: Object },
  setup(props) {
    const colors = TYPE_COLORS[props.data.nodeType] ?? TYPE_COLORS.clause
    return () =>
      h("div", { class: "code-node", style: { borderColor: colors.border } }, [
        h(Handle, { type: "target", position: Position.Top }),
        h(
          "div",
          {
            class: "code-node-header",
            style: { background: colors.header, color: colors.headerText }
          },
          props.data.label
        ),
        props.data.sourceHtml
          ? h("div", { class: "code-node-body highlight" }, [
              h(
                "table",
                { class: "code-table" },
                props.data.lines.map((line, i) =>
                  h("tr", { key: i }, [
                    h("td", { class: "line-number" }, props.data.startLine + i),
                    h("td", { class: "line-code", innerHTML: line })
                  ])
                )
              )
            ])
          : props.data.sourceText
            ? h("div", { class: "code-node-body highlight" }, [
                h(
                  "table",
                  { class: "code-table" },
                  props.data.sourceText
                    .split("\n")
                    .map((line, i) =>
                      h("tr", { key: i }, [
                        h("td", { class: "line-number" }, props.data.startLine + i),
                        h("td", { class: "line-code" }, [h("code", null, line)])
                      ])
                    )
                )
              ])
            : null,
        h(Handle, { type: "source", position: Position.Bottom })
      ])
  }
}

// ── Compact Node (for call graph) ──

const CompactNode = {
  props: { data: Object },
  setup(props) {
    const colors = TYPE_COLORS[props.data.nodeType] ?? TYPE_COLORS.external
    return () =>
      h(
        "div",
        {
          class: "compact-node",
          style: { borderColor: colors.border, background: colors.header + "15" }
        },
        [
          h(Handle, { type: "target", position: Position.Top }),
          h("span", { class: "compact-label", style: { color: colors.header } }, props.data.label),
          h(Handle, { type: "source", position: Position.Bottom })
        ]
      )
  }
}

// ── Layout helper ──

async function layoutAndApply(rawNodes, rawEdges, nodes, edges, fitView) {
  const nodeIds = rawNodes.map((n) => n.id)
  const nodeSizes = new Map()
  for (const n of rawNodes) {
    const lineCount = n.data.lines?.length ?? 1
    const maxLen = (n.data.lines ?? [n.data.label]).reduce((m, l) => Math.max(m, l.length), 0)
    nodeSizes.set(n.id, {
      width: Math.max(180, maxLen * 7.5 + 60),
      height: Math.max(40, lineCount * 18 + 30)
    })
  }

  const nodeIdSet = new Set(nodeIds)
  const validEdges = rawEdges.filter((e) => nodeIdSet.has(e.source) && nodeIdSet.has(e.target))

  const positions = await computeLayout(
    nodeIds,
    nodeSizes,
    validEdges.map((e) => ({ id: e.id, source: e.source, target: e.target }))
  )

  for (const n of rawNodes) {
    const pos = positions.get(n.id)
    if (pos) n.position = pos
  }

  nodes.value = rawNodes
  edges.value = validEdges
  await nextTick()
  fitView({ padding: 0.15 })
}

// ── Main App ──

const App = {
  props: { graphData: Object },
  setup(props) {
    const mode = ref("call_graph")
    const nodeTypes = { code: CodeNode, compact: CompactNode }
    const nodes = ref([])
    const edges = ref([])
    const { fitView } = useVueFlow()

    // Sidebar state
    const selectedModule = ref(null)
    const selectedFunction = ref(null)

    async function buildControlFlow() {
      const cf = props.graphData.control_flow
      if (!cf?.length) return

      const mod = selectedModule.value ? cf.find((m) => m.module === selectedModule.value) : cf[0]
      if (!mod) return

      const func = selectedFunction.value
        ? mod.functions.find((f) => f.id === selectedFunction.value)
        : mod.functions[0]
      if (!func) return

      selectedModule.value = mod.module
      selectedFunction.value = func.id

      const blocks = func.blocks
      const rawNodes = blocks.blocks.map((b) => ({
        id: b.id,
        type: "code",
        position: { x: 0, y: 0 },
        data: {
          label: b.label,
          nodeType: b.id === func.id ? "function" : "match",
          sourceHtml: b.source_html,
          sourceText: b.source_html ? null : b.lines?.join("\n"),
          lines: b.source_html ? b.source_html.split("\n") : (b.lines ?? []),
          startLine: b.start_line
        }
      }))

      const rawEdges = blocks.edges.map((e) => ({
        id: e.id,
        source: e.source,
        target: e.target,
        type: "smoothstep",
        style: { stroke: e.color, strokeWidth: 2 },
        label: e.label,
        labelStyle: { fill: e.color, fontSize: 11 }
      }))

      await layoutAndApply(rawNodes, rawEdges, nodes, edges, fitView)
    }

    async function buildCallGraph() {
      const cg = props.graphData.call_graph
      if (!cg) return

      const rawNodes = []
      for (const mod of cg.modules) {
        for (const func of mod.functions) {
          rawNodes.push({
            id: func.id,
            type: "compact",
            position: { x: 0, y: 0 },
            data: {
              label: func.id,
              nodeType: mod.file ? "call" : "external"
            }
          })
        }
      }

      const rawEdges = cg.edges.map((e) => ({
        id: e.id,
        source: e.source,
        target: e.target,
        type: "smoothstep",
        style: { stroke: e.color, strokeWidth: 1.5 }
      }))

      await layoutAndApply(rawNodes, rawEdges, nodes, edges, fitView)
    }

    async function buildDataFlow() {
      const df = props.graphData.data_flow
      if (!df) return

      const rawNodes = df.functions.map((f) => ({
        id: f.id,
        type: "code",
        position: { x: 0, y: 0 },
        data: {
          label: f.module ? `${f.module}.${f.label}` : f.label,
          nodeType: "data",
          sourceHtml: f.source_html,
          sourceText: null,
          lines: f.source_html ? f.source_html.split("\n") : [],
          startLine: f.start_line
        }
      }))

      const rawEdges = df.edges.map((e) => ({
        id: e.id,
        source: e.source,
        target: e.target,
        type: "smoothstep",
        style: { stroke: e.color, strokeWidth: 2 },
        label: e.label,
        labelStyle: { fill: "#16a34a", fontSize: 11 }
      }))

      await layoutAndApply(rawNodes, rawEdges, nodes, edges, fitView)
    }

    async function rebuild() {
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
    }

    watch(mode, rebuild)
    watch(selectedFunction, () => {
      if (mode.value === "control_flow") rebuild()
    })
    onMounted(rebuild)

    // Sidebar data
    const sidebarModules = computed(() => {
      const cf = props.graphData.control_flow
      if (!cf) return []
      return cf.map((m) => ({
        name: m.module ?? "(top-level)",
        module: m.module,
        functions: m.functions.map((f) => ({
          id: f.id,
          label: `${f.name}/${f.arity}`
        }))
      }))
    })

    function selectFunction(modName, funcId) {
      selectedModule.value = modName
      selectedFunction.value = funcId
      if (mode.value !== "control_flow") mode.value = "control_flow"
    }

    return () =>
      h("div", { class: "reach-container" }, [
        // Tab bar
        h("div", { class: "tab-bar" }, [
          h("div", { class: "tab-bar-tabs" }, [
            h(
              "button",
              {
                class: ["tab", mode.value === "control_flow" && "active"],
                onClick: () => (mode.value = "control_flow")
              },
              "Control Flow"
            ),
            h(
              "button",
              {
                class: ["tab", mode.value === "call_graph" && "active"],
                onClick: () => (mode.value = "call_graph")
              },
              "Call Graph"
            ),
            h(
              "button",
              {
                class: ["tab", mode.value === "data_flow" && "active"],
                onClick: () => (mode.value = "data_flow")
              },
              "Data Flow"
            )
          ])
        ]),

        h("div", { class: "main-area" }, [
          // Sidebar (control flow mode)
          mode.value === "control_flow"
            ? h("div", { class: "sidebar" }, [
                h("div", { class: "sidebar-title" }, "Functions"),
                ...sidebarModules.value.map((mod) =>
                  h("div", { class: "sidebar-module", key: mod.name }, [
                    h("div", { class: "sidebar-module-name" }, mod.name),
                    ...mod.functions.map((func) =>
                      h(
                        "button",
                        {
                          class: ["sidebar-func", selectedFunction.value === func.id && "active"],
                          onClick: () => selectFunction(mod.module, func.id),
                          key: func.id
                        },
                        func.label
                      )
                    )
                  ])
                )
              ])
            : null,

          // Graph area
          h(
            VueFlow,
            {
              nodes: nodes.value,
              edges: edges.value,
              nodeTypes,
              defaultEdgeOptions: { type: "smoothstep" },
              minZoom: 0.1,
              maxZoom: 3,
              class: "reach-flow"
            },
            { default: () => [h(MiniMap, { pannable: true, zoomable: true }), h(Controls)] }
          )
        ])
      ])
  }
}

createApp(App, { graphData: window.graphData }).mount("#app")
