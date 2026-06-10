"use client";

import { useCallback, useEffect, useMemo } from "react";
import {
  addEdge,
  Background,
  Connection,
  Controls,
  Edge,
  MarkerType,
  Node,
  ReactFlow,
  useEdgesState,
  useNodesState,
} from "@xyflow/react";

import { useAppStore } from "@/lib/store";

function layoutPosition(index: number, total: number) {
  const radius = Math.max(160, total * 28);
  const angle = (index / Math.max(total, 1)) * 2 * Math.PI;
  return {
    x: 300 + radius * Math.cos(angle),
    y: 280 + radius * Math.sin(angle),
  };
}

export function GraphView() {
  const graph = useAppStore((s) => s.graph);
  const refreshGraph = useAppStore((s) => s.refreshGraph);
  const removeNode = useAppStore((s) => s.removeNode);
  const connectNodes = useAppStore((s) => s.connectNodes);

  useEffect(() => {
    void refreshGraph();
  }, [refreshGraph]);

  const initialNodes: Node[] = useMemo(
    () =>
      graph.nodes.map((n, i) => ({
        id: n.id,
        position: layoutPosition(i, graph.nodes.length),
        data: { label: `${n.name}\n(${n.type})` },
        style: {
          whiteSpace: "pre-line",
          textAlign: "center",
          fontSize: 12,
          borderRadius: 8,
        },
      })),
    [graph.nodes]
  );

  const initialEdges: Edge[] = useMemo(
    () =>
      graph.edges.map((e) => ({
        id: e.id,
        source: e.source_id,
        target: e.target_id,
        label: e.relation,
        markerEnd: { type: MarkerType.ArrowClosed },
      })),
    [graph.edges]
  );

  const [nodes, setNodes, onNodesChange] = useNodesState(initialNodes);
  const [edges, setEdges, onEdgesChange] = useEdgesState(initialEdges);

  useEffect(() => {
    setNodes(initialNodes);
  }, [initialNodes, setNodes]);

  useEffect(() => {
    setEdges(initialEdges);
  }, [initialEdges, setEdges]);

  const onConnect = useCallback(
    (connection: Connection) => {
      setEdges((eds) => addEdge(connection, eds));
      if (connection.source && connection.target) {
        void connectNodes(connection.source, connection.target);
      }
    },
    [connectNodes, setEdges]
  );

  const onNodesDelete = useCallback(
    (deleted: Node[]) => {
      deleted.forEach((n) => void removeNode(n.id));
    },
    [removeNode]
  );

  return (
    <div className="h-full w-full">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        onNodesChange={onNodesChange}
        onEdgesChange={onEdgesChange}
        onConnect={onConnect}
        onNodesDelete={onNodesDelete}
        fitView
      >
        <Background />
        <Controls />
      </ReactFlow>
    </div>
  );
}
