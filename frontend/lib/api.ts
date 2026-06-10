const API_BASE_URL =
  process.env.NEXT_PUBLIC_API_BASE_URL ?? "http://localhost:8000";

export interface GraphNode {
  id: string;
  name: string;
  type: string;
  created_at: string;
}

export interface GraphEdge {
  id: string;
  source_id: string;
  target_id: string;
  relation: string;
  created_at: string;
}

export interface GraphData {
  nodes: GraphNode[];
  edges: GraphEdge[];
}

export interface ChatResponse {
  answer: string;
  extracted_triples: [string, string, string][];
  graph: GraphData;
}

async function handle<T>(res: Response): Promise<T> {
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`API ${res.status}: ${text}`);
  }
  return res.json() as Promise<T>;
}

export const api = {
  async sendChat(message: string): Promise<ChatResponse> {
    const res = await fetch(`${API_BASE_URL}/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message }),
    });
    return handle<ChatResponse>(res);
  },

  async getGraph(): Promise<GraphData> {
    const res = await fetch(`${API_BASE_URL}/graph`, { cache: "no-store" });
    return handle<GraphData>(res);
  },

  async deleteNode(nodeId: string): Promise<void> {
    const res = await fetch(`${API_BASE_URL}/graph/nodes/${nodeId}`, {
      method: "DELETE",
    });
    if (!res.ok && res.status !== 204) {
      throw new Error(`API ${res.status}`);
    }
  },

  async createEdge(
    sourceId: string,
    targetId: string,
    relation = "related_to"
  ): Promise<void> {
    const res = await fetch(`${API_BASE_URL}/graph/edges`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        source_id: sourceId,
        target_id: targetId,
        relation,
      }),
    });
    await handle(res);
  },
};
