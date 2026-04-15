import ReachGraph from "@reach/components/ReachGraph.vue"
import { createApp } from "vue"

createApp(ReachGraph, {
  graphData: (window as Record<string, unknown>).graphData
}).mount("#app")
