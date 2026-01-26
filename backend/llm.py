"""
LLM processing for conversation structure extraction.
Uses OpenAI GPT-4o directly.
"""
import os
import json
from datetime import datetime
from typing import List
from dotenv import load_dotenv
from openai import OpenAI
from models import TranscriptSegment, Structured, ActionItem, Event, CategoryEnum

# Load .env with override to ensure we get the correct key
load_dotenv(override=True)

client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))

# Minimum word count to process (below this = discard)
MIN_WORD_COUNT = 5


def segments_to_transcript_text(segments: List[TranscriptSegment]) -> str:
    """Convert transcript segments to a readable string."""
    lines = []
    for segment in segments:
        speaker_name = "User" if segment.is_user else f"Speaker {segment.speaker_id}"
        lines.append(f"{speaker_name}: {segment.text}")
    return "\n\n".join(lines)


def should_discard(transcript_text: str) -> bool:
    """Check if transcript is too short to be meaningful."""
    word_count = len(transcript_text.split())
    return word_count < MIN_WORD_COUNT


def get_category_list() -> str:
    """Get list of valid categories for the prompt."""
    return ", ".join([c.value for c in CategoryEnum])


def generate_structure(
    transcript_text: str,
    started_at: datetime,
    language: str = 'en',
    tz: str = 'UTC'
) -> dict:
    """
    Generate structured conversation data using GPT-4o.
    Returns a dict with title, overview, emoji, category, action_items, events.
    """

    # Check for discard
    if should_discard(transcript_text):
        return {
            'title': '',
            'overview': '',
            'emoji': '🧠',
            'category': 'other',
            'action_items': [],
            'events': [],
            'discarded': True
        }

    categories = get_category_list()

    prompt = f'''You are an expert content analyzer. Your task is to analyze the provided transcript and provide structure and clarity.
The content language is {language}. Use the same language {language} for your response.

For the title, write a clear, compelling headline (≤ 10 words) that captures the central topic and outcome. Use Title Case, avoid filler words, and include a key noun + verb where possible (e.g., "Team Finalizes Q2 Budget" or "Family Plans Weekend Road Trip").

For the overview, condense the content into a summary with the main topics discussed, making sure to capture the key points and important details.

For the emoji, select a single emoji that vividly reflects the core subject, mood, or outcome of the content. Strive for an emoji that is specific and evocative, rather than generic (e.g., prefer 🎉 for a celebration over 👍 for general agreement, or 💡 for a new idea over 🧠 for general thought).

For the category, classify the content into one of these categories: {categories}

For action_items, extract any tasks, todos, or commitments mentioned. Each action item should have:
- description: what needs to be done
- due_at: ISO datetime string if a specific time was mentioned, or null

For events, extract any calendar events mentioned that meet ALL these criteria:
- Confirmed commitment (not suggestions or "maybe")
- User involvement (user is expected to attend or take action)
- Specific timing (has concrete date/time)

Each event should have:
- title: event name
- description: brief description
- start: ISO datetime string in UTC
- duration: duration in minutes (default 30)

For date context, this content was captured on {started_at.isoformat()}. {tz} is the user's timezone; convert all event times to UTC.

Transcript:
```
{transcript_text}
```

Respond with a JSON object with these exact keys:
- title (string)
- overview (string)
- emoji (string, single emoji)
- category (string, one of the categories listed)
- action_items (array of objects with description, due_at)
- events (array of objects with title, description, start, duration)
'''

    try:
        response = client.chat.completions.create(
            model="gpt-4o",
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
            temperature=0.7,
            max_tokens=2000
        )

        result = json.loads(response.choices[0].message.content)

        # Validate category
        if result.get('category') not in [c.value for c in CategoryEnum]:
            result['category'] = 'other'

        # Cap event duration at 180 minutes
        for event in result.get('events', []):
            if event.get('duration', 30) > 180:
                event['duration'] = 180

        result['discarded'] = False
        return result

    except Exception as e:
        print(f"LLM Error: {e}")
        # Return minimal structure on error
        return {
            'title': 'Conversation',
            'overview': transcript_text[:200] + '...' if len(transcript_text) > 200 else transcript_text,
            'emoji': '🧠',
            'category': 'other',
            'action_items': [],
            'events': [],
            'discarded': False
        }
