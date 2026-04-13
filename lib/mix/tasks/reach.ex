defmodule Mix.Tasks.Reach do
  @moduledoc """
  Analyze code with Reach and generate an interactive dependency graph.

      mix reach
      mix reach lib/my_app/server.ex
      mix reach --dead-code
      mix reach --format dot

  ## Options

    * `--format` — output format: `html` (default), `dot`, `json`
    * `--output` — output directory (default: `reach_report`)
    * `--open` / `--no-open` — open browser after generating (default: true)
    * `--dead-code` — highlight dead code
    * `--module` — focus on a specific module
    * `--function` — focus on a specific function

  """

  use Mix.Task

  @shortdoc "Generate an interactive dependency graph"

  @switches [
    format: :string,
    output: :string,
    open: :boolean,
    dead_code: :boolean,
    module: :string,
    function: :string
  ]

  @aliases [f: :format, o: :output]

  @impl Mix.Task
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    Mix.Task.run("compile", ["--no-warnings-as-errors"])

    format = opts[:format] || "html"
    output_dir = opts[:output] || "reach_report"

    graph = build_graph(files)
    viz_opts = build_viz_opts(opts)
    vue_flow_data = Reach.Visualize.to_vue_flow(graph, viz_opts)

    case format do
      "html" -> render_html(vue_flow_data, output_dir, opts)
      "dot" -> render_dot(graph, output_dir)
      "json" -> render_json(vue_flow_data, output_dir)
      other -> Mix.raise("Unknown format: #{other}. Use html, dot, or json.")
    end
  end

  defp build_graph([]) do
    Mix.shell().info("Analyzing project...")
    Reach.Project.from_mix_project()
  end

  defp build_graph(files) do
    Mix.shell().info("Analyzing #{length(files)} file(s)...")
    Reach.Project.from_sources(files)
  end

  defp build_viz_opts(opts) do
    if opts[:dead_code], do: [dead_code: true], else: []
  end

  defp render_html(vue_flow_data, output_dir, opts) do
    ensure_json_encoder!()

    File.mkdir_p!(output_dir)

    json = json_encode!(vue_flow_data)
    html = html_shell(json)

    path = Path.join(output_dir, "index.html")
    File.write!(path, html)

    Mix.shell().info("Reach report: #{path}")

    if Keyword.get(opts, :open, true), do: open_browser(path)
  end

  defp render_dot(graph, output_dir) do
    File.mkdir_p!(output_dir)
    path = Path.join(output_dir, "reach.dot")

    {:ok, dot} = Reach.to_dot(graph)
    File.write!(path, dot)

    Mix.shell().info("DOT file: #{path}")
  end

  defp render_json(vue_flow_data, output_dir) do
    ensure_json_encoder!()

    File.mkdir_p!(output_dir)
    path = Path.join(output_dir, "reach.json")

    File.write!(path, json_encode!(vue_flow_data))

    Mix.shell().info("JSON file: #{path}")
  end

  defp ensure_json_encoder! do
    unless Code.ensure_loaded?(Jason) do
      Mix.raise("Jason is required for HTML/JSON output. Add {:jason, \"~> 1.0\"} to your deps.")
    end
  end

  defp json_encode!(data), do: Jason.encode!(data)

  defp open_browser(path) do
    abs = Path.expand(path)

    cmd =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:unix, _} -> "xdg-open"
        {:win32, _} -> "start"
      end

    System.cmd(cmd, [abs], stderr_to_stdout: true)
  end

  defp html_shell(graph_json) do
    ~s"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Reach — Dependency Graph</title>
    <script src="https://cdn.tailwindcss.com"><\/script>
    <style>
    body { margin: 0; }
    #cy { width: 100vw; height: 100vh; }
    #info-panel { transition: transform 0.2s; }
    <\/style>
    <\/head>
    <body class="bg-slate-950">
    <div id="cy"><\/div>

    <div id="info-panel" class="fixed top-4 right-4 bg-slate-900 border border-slate-700 rounded-xl p-4 shadow-xl text-slate-200 max-w-sm text-sm font-mono z-50 hidden">
      <div class="flex justify-between items-center mb-2">
        <span id="info-label" class="font-bold text-white"><\/span>
        <button onclick="document.getElementById('info-panel').classList.add('hidden')" class="text-slate-500 hover:text-white">×<\/button>
      <\/div>
      <div id="info-meta" class="space-y-1 text-xs"><\/div>
    <\/div>

    <div id="edge-filter" class="fixed bottom-4 left-1/2 -translate-x-1/2 bg-slate-900/90 backdrop-blur border border-slate-700 rounded-xl px-4 py-2 flex gap-2 text-xs z-50 flex-wrap justify-center"><\/div>

    <div id="controls" class="fixed top-4 left-4 flex flex-col gap-2 z-50">
      <button onclick="cy.fit()" class="bg-slate-800 border border-slate-600 text-slate-300 rounded-lg px-3 py-1.5 text-xs hover:bg-slate-700">Fit<\/button>
      <button onclick="cy.zoom(cy.zoom()*1.3);cy.center()" class="bg-slate-800 border border-slate-600 text-slate-300 rounded-lg px-3 py-1.5 text-xs hover:bg-slate-700">+<\/button>
      <button onclick="cy.zoom(cy.zoom()/1.3);cy.center()" class="bg-slate-800 border border-slate-600 text-slate-300 rounded-lg px-3 py-1.5 text-xs hover:bg-slate-700">−<\/button>
    <\/div>

    <script src="https://cdnjs.cloudflare.com/ajax/libs/cytoscape/3.30.4/cytoscape.min.js"><\/script>
    <script src="https://cdn.jsdelivr.net/npm/dagre@0.8.5/dist/dagre.min.js"><\/script>
    <script src="https://cdn.jsdelivr.net/npm/cytoscape-dagre@2.5.0/cytoscape-dagre.min.js"><\/script>
    <script>
    cytoscape.use(cytoscapeDagre);

    const graphData = #{graph_json};

    const edgeTypes = {
      data: {color:'#3b82f6', label:'Data flow'},
      control: {color:'#f97316', label:'Control dep'},
      containment: {color:'#6b7280', label:'Contains'},
      call: {color:'#8b5cf6', label:'Call'},
      match_binding: {color:'#3b82f6', label:'Match bind'},
      state_read: {color:'#10b981', label:'State read'},
      state_pass: {color:'#10b981', label:'State pass'},
      higher_order: {color:'#ec4899', label:'Higher order'},
      message_order: {color:'#f59e0b', label:'Message'},
      summary: {color:'#8b5cf6', label:'Summary'},
    };
    const activeTypes = new Set(Object.keys(edgeTypes));

    const elements = [];
    for (const n of graphData.nodes) {
      elements.push({data: {id: n.id, label: n.data.label, type: n.type, meta: n.data.meta, sourceSpan: n.data.source_span, dead: n.style.opacity === '0.3'}});
    }
    for (const e of graphData.edges) {
      const edgeType = e.label.split(':')[0].split(' ')[0];
      elements.push({data: {id: e.id, source: e.source, target: e.target, label: e.label, edgeType: edgeType, color: e.style.stroke}});
    }

    const cy = cytoscape({
      container: document.getElementById('cy'),
      elements: elements,
      style: [
        {selector: 'node', style: {
          'label': 'data(label)', 'text-valign': 'center', 'text-halign': 'center',
          'background-color': '#1e293b', 'color': '#e2e8f0',
          'border-width': 2, 'border-color': '#475569',
          'shape': 'roundrectangle', 'width': 'label', 'height': 'label',
          'padding': '10px', 'font-size': '12px', 'font-family': 'ui-monospace, SFMono-Regular, monospace',
          'text-wrap': 'wrap', 'text-max-width': '200px',
        }},
        {selector: 'node[type="module"]', style: {'background-color': '#312e81', 'border-color': '#6366f1', 'color': '#c7d2fe', 'font-size': '14px', 'font-weight': 'bold'}},
        {selector: 'node[type="function"]', style: {'background-color': '#1e3a5f', 'border-color': '#3b82f6', 'color': '#93c5fd', 'font-size': '13px'}},
        {selector: 'node[type="call"]', style: {'background-color': '#431407', 'border-color': '#f97316', 'color': '#fed7aa'}},
        {selector: 'node[type="var"]', style: {'background-color': '#052e16', 'border-color': '#10b981', 'color': '#86efac'}},
        {selector: 'node[?dead]', style: {'opacity': 0.3, 'border-style': 'dashed'}},
        {selector: 'node:selected', style: {'border-width': 3, 'border-color': '#f59e0b', 'overlay-opacity': 0.1, 'overlay-color': '#f59e0b'}},
        {selector: 'edge', style: {
          'width': 1.5, 'line-color': 'data(color)', 'target-arrow-color': 'data(color)',
          'target-arrow-shape': 'triangle', 'curve-style': 'bezier',
          'label': 'data(label)', 'font-size': '9px', 'color': '#64748b',
          'text-opacity': 0.7, 'text-background-color': '#0f172a', 'text-background-opacity': 0.8,
          'text-background-padding': '2px', 'text-rotation': 'autorotate',
        }},
        {selector: 'edge[edgeType="containment"]', style: {'line-style': 'dashed', 'target-arrow-shape': 'none'}},
        {selector: '.highlighted', style: {'line-color': '#ef4444', 'target-arrow-color': '#ef4444', 'width': 3, 'z-index': 999}},
        {selector: '.highlighted-node', style: {'border-color': '#ef4444', 'border-width': 3, 'overlay-color': '#ef4444', 'overlay-opacity': 0.1}},
        {selector: '.faded', style: {'opacity': 0.15}},
      ],
      layout: {name: 'dagre', rankDir: 'TB', nodeSep: 40, rankSep: 60, animate: false},
      wheelSensitivity: 0.3,
      minZoom: 0.05,
      maxZoom: 3,
    });

    // Click node → info panel
    cy.on('tap', 'node', function(evt) {
      const node = evt.target;
      const d = node.data();
      document.getElementById('info-label').textContent = d.label;
      const meta = document.getElementById('info-meta');
      meta.innerHTML = '';
      const add = (k, v) => { if (v != null && v !== '' && v !== 'nil') { const div = document.createElement('div'); div.textContent = k + ': ' + v; meta.appendChild(div); }};
      add('Type', d.type);
      if (d.meta) Object.entries(d.meta).forEach(([k,v]) => add(k, v));
      if (d.sourceSpan) add('Location', 'L' + d.sourceSpan.start_line + ':' + d.sourceSpan.start_col);
      document.getElementById('info-panel').classList.remove('hidden');

      // Highlight connected edges
      cy.elements().removeClass('highlighted highlighted-node faded');
      const connected = node.connectedEdges().connectedNodes();
      cy.elements().addClass('faded');
      connected.removeClass('faded');
      node.removeClass('faded');
      node.connectedEdges().removeClass('faded').addClass('highlighted');
      node.addClass('highlighted-node');
    });

    cy.on('tap', function(evt) {
      if (evt.target === cy) {
        cy.elements().removeClass('highlighted highlighted-node faded');
        document.getElementById('info-panel').classList.add('hidden');
      }
    });

    // Edge type filter
    const filterEl = document.getElementById('edge-filter');
    Object.entries(edgeTypes).forEach(([type, {label}]) => {
      const btn = document.createElement('button');
      btn.textContent = label;
      btn.className = 'px-2 py-1 rounded-lg transition bg-slate-700 text-white';
      btn.onclick = () => {
        if (activeTypes.has(type)) { activeTypes.delete(type); btn.className = 'px-2 py-1 rounded-lg transition bg-transparent text-slate-500'; }
        else { activeTypes.add(type); btn.className = 'px-2 py-1 rounded-lg transition bg-slate-700 text-white'; }
        cy.edges().forEach(e => {
          const et = e.data('edgeType');
          if (activeTypes.has(et) || !edgeTypes[et]) e.show(); else e.hide();
        });
      };
      filterEl.appendChild(btn);
    });

    cy.fit(undefined, 40);
    <\/script>
    <\/body>
    <\/html>
    """
  end
end
