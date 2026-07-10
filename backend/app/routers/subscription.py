"""Subscription tier is assigned at device registration for now."""

from fastapi import APIRouter

router = APIRouter(prefix="/subscription", tags=["subscription"])
