"""Agent tools: thin wrappers over GraphRAG retrieval and graph generation."""

from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..rag import retrieve_graph_context
from ..schemas import ChatMessage, StagingGraph


async def search_graph(session: AsyncSession, query: str) -> dict:
    """GraphRAG retrieval: serialized facts + node ids for UI navigation."""
    rc = await retrieve_graph_context(session, query)
    return {
        "context": rc.context,
        "facts_found": bool(rc.context),
        "seed_node_ids": [str(i) for i in rc.seed_node_ids],
        "node_ids": [str(i) for i in rc.node_ids],
    }


async def generate_graph(
    session: AsyncSession,
    messages: list[ChatMessage],
    *,
    skip_refinement: bool = False,
) -> StagingGraph:
    """Legacy triple extraction removed — use journal semantic-chunk ingest instead."""
    del session, messages, skip_refinement
    return StagingGraph(nodes=[], edges=[])
