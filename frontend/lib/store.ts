import { create } from "zustand";

import { api, GraphData } from "./api";

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

interface AppState {
  messages: ChatMessage[];
  graph: GraphData;
  isSending: boolean;
  error: string | null;

  sendMessage: (text: string) => Promise<void>;
  refreshGraph: () => Promise<void>;
  removeNode: (nodeId: string) => Promise<void>;
  connectNodes: (sourceId: string, targetId: string) => Promise<void>;
}

const emptyGraph: GraphData = { nodes: [], edges: [] };

export const useAppStore = create<AppState>((set, get) => ({
  messages: [],
  graph: emptyGraph,
  isSending: false,
  error: null,

  sendMessage: async (text: string) => {
    const trimmed = text.trim();
    if (!trimmed || get().isSending) return;

    set((s) => ({
      messages: [...s.messages, { role: "user", content: trimmed }],
      isSending: true,
      error: null,
    }));

    try {
      const res = await api.sendChat(trimmed);
      set((s) => ({
        messages: [...s.messages, { role: "assistant", content: res.answer }],
        graph: res.graph,
        isSending: false,
      }));
    } catch (e) {
      set({ error: (e as Error).message, isSending: false });
    }
  },

  refreshGraph: async () => {
    try {
      const graph = await api.getGraph();
      set({ graph });
    } catch (e) {
      set({ error: (e as Error).message });
    }
  },

  removeNode: async (nodeId: string) => {
    await api.deleteNode(nodeId);
    await get().refreshGraph();
  },

  connectNodes: async (sourceId: string, targetId: string) => {
    await api.createEdge(sourceId, targetId);
    await get().refreshGraph();
  },
}));
