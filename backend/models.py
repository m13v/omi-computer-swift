"""
Models for conversation processing.
Adapted from OMI backend.
"""
from datetime import datetime, timezone
from enum import Enum
from typing import List, Optional
from pydantic import BaseModel, Field


class CategoryEnum(str, Enum):
    personal = 'personal'
    education = 'education'
    health = 'health'
    finance = 'finance'
    legal = 'legal'
    philosophy = 'philosophy'
    spiritual = 'spiritual'
    science = 'science'
    entrepreneurship = 'entrepreneurship'
    parenting = 'parenting'
    romance = 'romantic'
    travel = 'travel'
    inspiration = 'inspiration'
    technology = 'technology'
    business = 'business'
    social = 'social'
    work = 'work'
    sports = 'sports'
    politics = 'politics'
    literature = 'literature'
    history = 'history'
    architecture = 'architecture'
    music = 'music'
    weather = 'weather'
    news = 'news'
    entertainment = 'entertainment'
    psychology = 'psychology'
    real = 'real'
    design = 'design'
    family = 'family'
    economics = 'economics'
    environment = 'environment'
    other = 'other'


class ActionItem(BaseModel):
    description: str = Field(description="The action item to be completed")
    completed: bool = False
    due_at: Optional[datetime] = Field(default=None, description="When the action item is due")


class MemoryCategory(str, Enum):
    """Categories for extracted memories."""
    system = "system"          # Facts ABOUT the user (preferences, network, projects)
    interesting = "interesting"  # External wisdom WITH attribution from others


class Memory(BaseModel):
    """A memory extracted from conversation - long-term knowledge about the user."""
    content: str = Field(description="The memory content (max 15 words)")
    category: MemoryCategory = Field(description="The category of the memory")


class Event(BaseModel):
    title: str = Field(description="The title of the event")
    description: str = Field(description="A brief description of the event", default='')
    start: datetime = Field(description="The start date and time of the event")
    duration: int = Field(description="The duration of the event in minutes", default=30)


class Structured(BaseModel):
    title: str = Field(description="A title/name for this conversation", default='')
    overview: str = Field(
        description="A brief overview of the conversation, highlighting the key details from it",
        default='',
    )
    emoji: str = Field(description="An emoji to represent the conversation", default='🧠')
    category: str = Field(description="A category for this conversation", default='other')
    action_items: List[ActionItem] = Field(description="A list of action items from the conversation", default=[])
    events: List[Event] = Field(
        description="A list of events extracted from the conversation",
        default=[],
    )


class TranscriptSegment(BaseModel):
    text: str
    speaker: str = 'SPEAKER_00'
    speaker_id: int = 0
    is_user: bool = False
    start: float = 0.0
    end: float = 0.0


class CreateConversationRequest(BaseModel):
    transcript_segments: List[TranscriptSegment]
    started_at: datetime
    finished_at: datetime
    language: str = 'en'
    timezone: str = 'UTC'


class CreateConversationResponse(BaseModel):
    id: str
    status: str
    discarded: bool
