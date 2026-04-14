import cytoscape from "cytoscape"

interface NodeData {
  id: string
  type: string
  data: {
    label: string
    type: string
    meta: Record<string, string | number | null>
    source_span: { start_line: number; start_col: number; file: string } | null
  }
  style: { opacity: string; borderWidth: string }
}

interface EdgeData {
  id: string
  source: string
  target: string
  label: string
  style: { stroke: string }
  animated: boolean
}

interface GraphData {
  nodes: NodeData[]
  edges: EdgeData[]
}

const EDGE_TYPES: Record<string, { color: string; label: string }> = {
  data: { color: "#3b82f6", label: "Data flow" },
  control: { color: "#f97316", label: "Control dep" },
  containment: { color: "#6b7280", label: "Contains" },
  call: { color: "#8b5cf6", label: "Call" },
  match_binding: { color: "#3b82f6", label: "Match bind" },
  state_read: { color: "#10b981", label: "State read" },
  state_pass: { color: "#10b981", label: "State pass" },
  higher_order: { color: "#ec4899", label: "Higher order" },
  message_order: { color: "#f59e0b", label: "Message" },
  summary: { color: "#8b5cf6", label: "Summary" }
}

const activeTypes = new Set(Object.keys(EDGE_TYPES))

declare global {
  interface Window {
    cy: cytoscape.Core
    graphData: GraphData
  }
}

function edgeTypeOf(label: string): string {
  return label.split(":")[0].split(" ")[0]
}

const STYLES: cytoscape.Stylesheet[] = [
  {
    selector: "node",
    style: {
      label: "data(label)",
      "text-valign": "center",
      "text-halign": "center",
      "background-color": "#1e293b",
      color: "#e2e8f0",
      "border-width": 2,
      "border-color": "#475569",
      shape: "roundrectangle",
      width: "label",
      height: "label",
      padding: "10px",
      "font-size": "12px",
      "font-family": "ui-monospace, SFMono-Regular, monospace",
      "text-wrap": "wrap",
      "text-max-width": "200px"
    }
  },
  {
    selector: 'node[type="module"]',
    style: {
      "background-color": "#312e81",
      "border-color": "#6366f1",
      color: "#c7d2fe",
      "font-size": "14px",
      "font-weight": "bold"
    }
  },
  {
    selector: 'node[type="function"]',
    style: {
      "background-color": "#1e3a5f",
      "border-color": "#3b82f6",
      color: "#93c5fd",
      "font-size": "13px"
    }
  },
  {
    selector: 'node[type="call"]',
    style: { "background-color": "#431407", "border-color": "#f97316", color: "#fed7aa" }
  },
  {
    selector: 'node[type="var"]',
    style: { "background-color": "#052e16", "border-color": "#10b981", color: "#86efac" }
  },
  { selector: "node[?dead]", style: { opacity: 0.3, "border-style": "dashed" } },
  {
    selector: "node[?tainted]",
    style: {
      "border-color": "#ef4444",
      "border-width": 3,
      "overlay-color": "#ef4444",
      "overlay-opacity": 0.1
    }
  },
  {
    selector: "node:selected",
    style: {
      "border-width": 3,
      "border-color": "#f59e0b",
      "overlay-opacity": 0.1,
      "overlay-color": "#f59e0b"
    }
  },
  {
    selector: "edge",
    style: {
      width: 1.5,
      "line-color": "data(color)",
      "target-arrow-color": "data(color)",
      "target-arrow-shape": "triangle",
      "curve-style": "bezier",
      label: "data(label)",
      "font-size": "11px",
      "font-family": "ui-monospace, SFMono-Regular, monospace",
      color: "#94a3b8",
      "text-background-color": "#0f172a",
      "text-background-opacity": 0.9,
      "text-background-padding": "4px",
      "text-background-shape": "roundrectangle",
      "text-rotation": "none"
    }
  },
  {
    selector: 'edge[edgeType="containment"]',
    style: { "line-style": "dashed", "target-arrow-shape": "none", label: "" }
  },
  {
    selector: ".highlighted",
    style: { "line-color": "#ef4444", "target-arrow-color": "#ef4444", width: 3, "z-index": 999 }
  },
  {
    selector: ".highlighted-node",
    style: {
      "border-color": "#ef4444",
      "border-width": 3,
      "overlay-color": "#ef4444",
      "overlay-opacity": 0.1
    }
  },
  { selector: ".faded", style: { opacity: 0.15 } }
]

function showInfoPanel(node: cytoscape.NodeSingular) {
  const d = node.data()
  document.getElementById("info-label")!.textContent = d.label
  const meta = document.getElementById("info-meta")!
  meta.innerHTML = ""
  const add = (k: string, v: unknown) => {
    if (v != null && v !== "" && v !== "nil") {
      const div = document.createElement("div")
      div.textContent = `${k}: ${v}`
      meta.appendChild(div)
    }
  }
  add("Type", d.type)
  if (d.meta) for (const [k, v] of Object.entries(d.meta)) add(k, v)
  if (d.sourceSpan) {
    add("Location", `L${d.sourceSpan.start_line}:${d.sourceSpan.start_col}`)
    add("File", d.sourceSpan.file)
  }
  document.getElementById("info-panel")!.classList.remove("hidden")
}

function setupEdgeFilters(cy: cytoscape.Core) {
  const container = document.getElementById("edge-filter")!
  for (const [type, { label }] of Object.entries(EDGE_TYPES)) {
    const btn = document.createElement("button")
    btn.textContent = label
    btn.className = "filter-btn active"
    btn.addEventListener("click", () => {
      if (activeTypes.has(type)) {
        activeTypes.delete(type)
        btn.classList.remove("active")
      } else {
        activeTypes.add(type)
        btn.classList.add("active")
      }
      cy.edges().forEach((e) => {
        const et = e.data("edgeType")
        if (activeTypes.has(et) || !EDGE_TYPES[et]) e.show()
        else e.hide()
      })
    })
    container.appendChild(btn)
  }
}

async function computeElkLayout(data: GraphData) {
  // @ts-expect-error ELK loaded via separate script tag
  const elk = new window.ELK()

  const elkGraph = {
    id: "root",
    layoutOptions: {
      "elk.algorithm": "layered",
      "elk.direction": "DOWN",
      "elk.layered.spacing.nodeNodeBetweenLayers": "60",
      "elk.spacing.nodeNode": "30",
      "elk.layered.crossingMinimization.strategy": "LAYER_SWEEP",
      "elk.layered.nodePlacement.strategy": "NETWORK_SIMPLEX"
    } as LayoutOptions,
    children: data.nodes.map((n) => ({
      id: n.id,
      width: Math.max(80, n.data.label.length * 8 + 20),
      height: 30
    })),
    edges: data.edges.map((e) => ({
      id: e.id,
      sources: [e.source],
      targets: [e.target]
    }))
  }

  return elk.layout(elkGraph)
}

async function init() {
  const graphData = window.graphData
  if (!graphData) return
  const layout = await computeElkLayout(graphData)
  const positions: Record<string, { x: number; y: number }> = {}
  for (const child of layout.children ?? []) {
    positions[child.id] = { x: child.x ?? 0, y: child.y ?? 0 }
  }

  const elements: cytoscape.ElementDefinition[] = []
  for (const n of graphData.nodes) {
    const pos = positions[n.id] ?? { x: 0, y: 0 }
    elements.push({
      data: {
        id: n.id,
        label: n.data.label,
        type: n.type,
        meta: n.data.meta,
        sourceSpan: n.data.source_span,
        dead: n.style.opacity === "0.3",
        tainted: n.style.borderWidth === "3px"
      },
      position: pos
    })
  }
  for (const e of graphData.edges) {
    elements.push({
      data: {
        id: e.id,
        source: e.source,
        target: e.target,
        label: e.label,
        edgeType: edgeTypeOf(e.label),
        color: e.style.stroke
      }
    })
  }
  const cy = cytoscape({
    container: document.getElementById("graph-container"),
    elements,
    style: STYLES,
    layout: { name: "preset" },
    wheelSensitivity: 0.3,
    minZoom: 0.02,
    maxZoom: 3
  })

  window.cy = cy

  // Ensure all nodes/edges are visible after layout
  cy.elements().show()
  cy.fit(undefined, 40)

  cy.on("tap", "node", (evt) => {
    const node = evt.target
    cy.elements().removeClass("highlighted highlighted-node faded")
    const connected = node.connectedEdges().connectedNodes()
    cy.elements().addClass("faded")
    connected.removeClass("faded")
    node.removeClass("faded")
    node.connectedEdges().removeClass("faded").addClass("highlighted")
    node.addClass("highlighted-node")
    showInfoPanel(node)
  })

  cy.on("tap", (evt) => {
    if (evt.target === cy) {
      cy.elements().removeClass("highlighted highlighted-node faded")
      document.getElementById("info-panel")!.classList.add("hidden")
    }
  })

  setupEdgeFilters(cy)

  document.getElementById("btn-fit")!.addEventListener("click", () => cy.fit(undefined, 40))
  document.getElementById("btn-zoom-in")!.addEventListener("click", () => {
    cy.zoom(cy.zoom() * 1.3)
    cy.center()
  })
  document.getElementById("btn-zoom-out")!.addEventListener("click", () => {
    cy.zoom(cy.zoom() / 1.3)
    cy.center()
  })
}

init().catch((e) => {
  document.title = "ERR: " + (e instanceof Error ? e.message : String(e))
  console.error(e)
})
