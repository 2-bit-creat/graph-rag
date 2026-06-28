from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from .. import crud
from ..db import (
    DEFAULT_ENTITY_TYPES,
    DEFAULT_ONTOLOGY_NAME,
    DEFAULT_RELATION_TYPES,
    get_session,
)
from ..ontology_presets import ONTOLOGY_PRESETS
from ..schemas import (
    OntologyOut,
    OntologyPresetOut,
    OntologyUpdate,
    OntologyVersionOut,
    OntologyVersionSummary,
)

router = APIRouter(prefix="/ontology", tags=["ontology"])


@router.get("", response_model=OntologyOut)
async def read_ontology(session: AsyncSession = Depends(get_session)) -> OntologyOut:
    ontology = await crud.get_ontology(session)
    if ontology is None:
        return OntologyOut(
            name=DEFAULT_ONTOLOGY_NAME,
            entity_types=DEFAULT_ENTITY_TYPES,
            relation_types=DEFAULT_RELATION_TYPES,
        )
    return OntologyOut(
        name=ontology.name,
        entity_types=ontology.entity_types,
        relation_types=ontology.relation_types,
    )


@router.put("", response_model=OntologyOut)
async def update_ontology(
    payload: OntologyUpdate, session: AsyncSession = Depends(get_session)
) -> OntologyOut:
    ontology = await crud.save_ontology(
        session,
        entity_types=[e.model_dump() for e in payload.entity_types],
        relation_types=payload.relation_types,
        note=payload.note,
        ontology_name=payload.name,
    )
    return OntologyOut(
        name=ontology.name,
        entity_types=ontology.entity_types,
        relation_types=ontology.relation_types,
    )


@router.get("/presets", response_model=list[OntologyPresetOut])
async def list_presets() -> list[OntologyPresetOut]:
    return [
        OntologyPresetOut(
            ontology_name=preset["ontology_name"],
            description=preset["description"],
            entity_type_count=len(preset["entity_types"]),
            relation_type_count=len(preset["relation_types"]),
        )
        for preset in ONTOLOGY_PRESETS.values()
    ]


@router.post("/presets/{preset_name}/apply", response_model=OntologyOut)
async def apply_preset(
    preset_name: str, session: AsyncSession = Depends(get_session)
) -> OntologyOut:
    ontology = await crud.apply_ontology_preset(session, preset_name)
    if ontology is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="preset not found"
        )
    return OntologyOut(
        name=ontology.name,
        entity_types=ontology.entity_types,
        relation_types=ontology.relation_types,
    )


@router.get("/versions", response_model=list[OntologyVersionSummary])
async def list_versions(
    session: AsyncSession = Depends(get_session),
) -> list[OntologyVersionSummary]:
    versions = await crud.list_ontology_versions(session)
    return [
        OntologyVersionSummary(
            id=v.id,
            version_number=v.version_number,
            ontology_name=v.ontology_name,
            note=v.note,
            entity_type_count=len(v.entity_types),
            relation_type_count=len(v.relation_types),
            created_at=v.created_at,
        )
        for v in versions
    ]


@router.get("/versions/{version_id}", response_model=OntologyVersionOut)
async def read_version(
    version_id: int, session: AsyncSession = Depends(get_session)
) -> OntologyVersionOut:
    version = await crud.get_ontology_version(session, version_id)
    if version is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="version not found")
    return OntologyVersionOut(
        id=version.id,
        version_number=version.version_number,
        ontology_name=version.ontology_name,
        note=version.note,
        entity_types=version.entity_types,
        relation_types=version.relation_types,
        created_at=version.created_at,
    )


@router.post("/versions/{version_id}/restore", response_model=OntologyOut)
async def restore_version(
    version_id: int, session: AsyncSession = Depends(get_session)
) -> OntologyOut:
    ontology = await crud.restore_ontology_version(session, version_id)
    if ontology is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="version not found")
    return OntologyOut(
        name=ontology.name,
        entity_types=ontology.entity_types,
        relation_types=ontology.relation_types,
    )
