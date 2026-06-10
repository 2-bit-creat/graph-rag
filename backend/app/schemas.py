import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict


class NodeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    type: str
    created_at: datetime


class EdgeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    source_id: uuid.UUID
    target_id: uuid.UUID
    relation: str
    created_at: datetime


class GraphOut(BaseModel):
    nodes: list[NodeOut]
    edges: list[EdgeOut]


class ChatRequest(BaseModel):
    message: str


class ChatResponse(BaseModel):
    answer: str
    extracted_triples: list[tuple[str, str, str]]
    graph: GraphOut


class EdgeCreate(BaseModel):
    source_id: uuid.UUID
    target_id: uuid.UUID
    relation: str = "related_to"
