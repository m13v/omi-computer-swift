"""
LLM processing for conversation structure extraction.
Uses OpenAI GPT-5.1 directly.
Prompts adapted from OMI backend.
"""
import os
import json
from dataclasses import dataclass, field
from datetime import datetime
from typing import List, Optional
from dotenv import load_dotenv
from openai import OpenAI
from models import TranscriptSegment, Structured, ActionItem, Event, CategoryEnum, Memory, MemoryCategory

# Load .env with override to ensure we get the correct key
load_dotenv(override=True)

client = OpenAI(api_key=os.getenv('OPENAI_API_KEY'))

# Model to use
MODEL = "gpt-5.1"

# Minimum word count to process (below this = discard)
MIN_WORD_COUNT = 5


@dataclass
class CalendarParticipant:
    """Participant in a calendar meeting."""
    name: Optional[str] = None
    email: Optional[str] = None


@dataclass
class CalendarMeetingContext:
    """Context from a calendar meeting for better conversation analysis."""
    title: str = ""
    start_time: Optional[datetime] = None
    duration_minutes: int = 30
    platform: Optional[str] = None
    participants: List[CalendarParticipant] = field(default_factory=list)
    notes: Optional[str] = None
    meeting_link: Optional[str] = None


def build_calendar_context_str(calendar_meeting_context: CalendarMeetingContext) -> str:
    """Build the calendar context string for the prompt."""
    if not calendar_meeting_context:
        return ""

    participants_str = ", ".join(
        [
            f"{p.name} <{p.email}>" if p.name and p.email else p.name or p.email or "Unknown"
            for p in calendar_meeting_context.participants
        ]
    )

    start_time_str = (
        calendar_meeting_context.start_time.strftime('%Y-%m-%d %H:%M UTC')
        if calendar_meeting_context.start_time else 'Not specified'
    )

    context_str = f"""CALENDAR MEETING CONTEXT:
- Meeting Title: {calendar_meeting_context.title}
- Scheduled Time: {start_time_str}
- Duration: {calendar_meeting_context.duration_minutes} minutes
- Platform: {calendar_meeting_context.platform or 'Not specified'}
- Participants: {participants_str or 'None listed'}"""

    if calendar_meeting_context.notes:
        context_str += f"\n- Meeting Notes: {calendar_meeting_context.notes}"
    if calendar_meeting_context.meeting_link:
        context_str += f"\n- Meeting Link: {calendar_meeting_context.meeting_link}"

    return context_str


def segments_to_transcript_text(segments: List[TranscriptSegment]) -> str:
    """Convert transcript segments to a readable string."""
    lines = []
    for segment in segments:
        speaker_name = "User" if segment.is_user else f"Speaker {segment.speaker_id}"
        lines.append(f"{speaker_name}: {segment.text}")
    return "\n\n".join(lines)


def should_discard_by_word_count(transcript_text: str) -> bool:
    """Quick check if transcript is too short to be meaningful."""
    word_count = len(transcript_text.split())
    return word_count < MIN_WORD_COUNT


def should_discard_conversation(transcript_text: str) -> bool:
    """
    Use LLM to determine if conversation should be discarded.
    Adapted from OMI backend.
    """
    # Quick optimization: long transcripts are very unlikely to be discarded
    if transcript_text and len(transcript_text.split()) > 100:
        return False

    # If too short, discard without LLM call
    if should_discard_by_word_count(transcript_text):
        return True

    prompt = f'''You will receive a transcript. Your task is to decide if this content is meaningful enough to be saved as a memory. Length is never a reason to discard.

Task: Decide if the content should be saved as conversation summary.

KEEP (output: discard = false) if the content contains any of the following:
• A task, request, or action item.
• A decision, commitment, or plan.
• A question that requires follow-up.
• Personal facts, preferences, or details likely useful later (e.g., remembering a person, place, or object).
• An important event, social interaction, or significant moment with meaningful context or consequences.
• An insight, summary, or key takeaway that provides value.
• A visually significant scene (e.g., a whiteboard with notes, a document, a memorable view, a person's face).

DISCARD (output: discard = true) if the content is:
• Trivial conversation snippets (e.g., brief apologies, casual remarks, single-sentence comments without context).
• Very brief interactions (5-10 seconds) that lack actionable content or meaningful context.
• Casual acknowledgments, greetings, or passing comments that don't contain useful information.
• Blurry photos, uninteresting scenery with no context, or content that doesn't meet the KEEP criteria above.
• Feels like asking Siri or other AI assistant something in 1-2 sentences or using voice to type something in a chat for 5-10 seconds.

Return exactly one line:
discard = <True|False>

Content:
```{transcript_text}```

Respond with JSON: {{"discard": true}} or {{"discard": false}}'''

    try:
        response = client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
            temperature=0.3,
            max_completion_tokens=100
        )
        result = json.loads(response.choices[0].message.content)
        return result.get('discard', False)
    except Exception as e:
        print(f"Error in discard check: {e}")
        return False


def get_category_list() -> str:
    """Get list of valid categories for the prompt."""
    return ", ".join([c.value for c in CategoryEnum])


def extract_action_items(
    transcript_text: str,
    started_at: datetime,
    language: str = 'en',
    tz: str = 'UTC',
    existing_action_items: Optional[List[dict]] = None,
    calendar_meeting_context: Optional[CalendarMeetingContext] = None
) -> List[dict]:
    """
    Dedicated function to extract action items from conversation content.
    Adapted from OMI backend with comprehensive extraction rules.
    """
    if not transcript_text or not transcript_text.strip():
        return []

    # Build calendar context if available
    calendar_context_str = build_calendar_context_str(calendar_meeting_context) if calendar_meeting_context else ""

    # Build existing items context for deduplication
    existing_items_context = ""
    if existing_action_items:
        items_list = []
        for item in existing_action_items:
            desc = item.get('description', '')
            due = item.get('due_at')
            due_str = due if due else 'No due date'
            completed = '✓ Completed' if item.get('completed', False) else 'Pending'
            items_list.append(f"  • {desc} (Due: {due_str}) [{completed}]")
        existing_items_context = f"\n\nEXISTING ACTION ITEMS FROM PAST 2 DAYS ({len(items_list)} items):\n" + "\n".join(items_list)

    # Build calendar context section for prompt
    calendar_prompt_section = ""
    if calendar_meeting_context:
        calendar_prompt_section = f"""
{calendar_context_str}

CRITICAL: If CALENDAR MEETING CONTEXT is provided with participant names, you MUST use those names:
- The conversation DEFINITELY happened between the named participants
- NEVER use "Speaker 0", "Speaker 1", "Speaker 2", etc. when participant names are available
- Match transcript speakers to participant names by analyzing the conversation context
- Use participant names in ALL action items (e.g., "Follow up with Sarah" NOT "Follow up with Speaker 0")
- Reference the meeting title/context when relevant to the action item
- Consider the scheduled meeting time and duration when extracting due dates
- If you cannot confidently match a speaker to a name, use the action description without speaker references
"""

    prompt = f'''You are an expert action item extractor. Your sole purpose is to identify and extract actionable tasks from the provided content.

The content language is {language}. Use the same language {language} for your response.
{calendar_prompt_section}
EXPLICIT TASK/REMINDER REQUESTS (HIGHEST PRIORITY)

When the primary user OR someone speaking to them uses these patterns, ALWAYS extract the task:
- "Remind me to X" / "Remember to X" → EXTRACT "X"
- "Don't forget to X" / "Don't let me forget X" → EXTRACT "X"
- "Add task X" / "Create task X" / "Make a task for X" → EXTRACT "X"
- "Note to self: X" / "Mental note: X" → EXTRACT "X"
- "Task: X" / "Todo: X" / "To do: X" → EXTRACT "X"
- "I need to remember to X" → EXTRACT "X"
- "Put X on my list" / "Add X to my tasks" → EXTRACT "X"
- "Set a reminder for X" / "Can you remind me X" → EXTRACT "X"
- "You need to X" / "You should X" / "Make sure you X" (said TO the user) → EXTRACT "X"

These explicit requests bypass importance/timing filters. If someone explicitly asks for a reminder or task, extract it.

Examples:
- User says "Remind me to buy milk" → Extract "Buy milk"
- Someone tells user "Don't forget to call your mom" → Extract "Call mom"
- User says "Add task pick up dry cleaning" → Extract "Pick up dry cleaning"
- User says "Note to self, check tire pressure" → Extract "Check tire pressure"
{existing_items_context}

CRITICAL DEDUPLICATION RULES (Check BEFORE extracting):
• DO NOT extract action items that are >95% similar to existing ones listed above
• Check both the description AND the due date/timeframe
• Consider semantic similarity, not just exact word matches
• Examples of what counts as DUPLICATES (DO NOT extract):
  - "Call John" vs "Phone John" → DUPLICATE
  - "Finish report by Friday" (existing) vs "Complete report by end of week" → DUPLICATE
  - "Buy milk" (existing) vs "Get milk from store" → DUPLICATE
  - "Email Sarah about meeting" (existing) vs "Send email to Sarah regarding the meeting" → DUPLICATE
• Examples of what is NOT duplicate (OK to extract):
  - "Buy groceries" (existing) vs "Buy milk" → NOT duplicate (different scope)
  - "Call dentist" (existing) vs "Call plumber" → NOT duplicate (different person/service)
  - "Submit report by March 1st" (existing) vs "Submit report by March 15th" → NOT duplicate (different deadlines)
• If you're unsure whether something is a duplicate, err on the side of treating it as a duplicate (DON'T extract)

WORKFLOW:
1. FIRST: Read the ENTIRE conversation carefully to understand the full context
2. SECOND: Check for EXPLICIT task requests (remind me, add task, don't forget, etc.) - ALWAYS extract these
3. THIRD: For IMPLICIT tasks - be extremely aggressive with filtering:
   - Is the user ALREADY doing this? SKIP IT
   - Is this truly important enough to remind a busy person? If ANY doubt, SKIP IT
   - Would missing this have real consequences? If not obvious, SKIP IT
   - Better to extract 0 implicit tasks than flood the user with noise
4. FOURTH: Extract timing information separately and put it in the due_at field
5. FIFTH: Clean the description - remove ALL time references and vague words
6. SIXTH: Final check - description should be timeless and specific (e.g., "Buy groceries" NOT "buy them by tomorrow")

CRITICAL CONTEXT:
• These action items are primarily for the PRIMARY USER who is having/recording this conversation
• The user is the person wearing the device or initiating the conversation
• Focus on tasks the primary user needs to track and act upon
• Include tasks for OTHER people ONLY if:
  - The primary user is dependent on that task being completed
  - It's super crucial for the primary user to track it
  - The primary user needs to follow up on it

BALANCE QUALITY AND USER INTENT:
• For EXPLICIT requests (remind me, add task, don't forget, etc.) - ALWAYS extract
• For IMPLICIT tasks inferred from conversation - be very selective, better to extract 0 than flood the user
• Think: "Did the user ask for this reminder, or am I guessing they need it?"
• If the user explicitly asked for a task/reminder, respect their request even if it seems trivial

STRICT FILTERING RULES - Include ONLY tasks that meet ALL these criteria:

1. **Clear Ownership & Relevance to Primary User**:
   - Identify which speaker is the primary user based on conversational context
   - Look for cues: who is asking questions, who is receiving advice/tasks, who initiates topics
   - For tasks assigned to the primary user: phrase them directly (start with verb)
   - For tasks assigned to others: include them ONLY if primary user is dependent on them or needs to track them
   - **CRITICAL**: When CALENDAR MEETING CONTEXT provides participant names:
     * Analyze the transcript to match speakers to the named participants
     * Use the actual participant names in ALL action items
     * ABSOLUTELY NEVER use "Speaker 0", "Speaker 1", "Speaker 2", etc.
     * Example: "Follow up with Sarah about budget" NOT "Follow up with Speaker 0 about budget"
   - If no calendar context: NEVER use "Speaker 0", "Speaker 1", etc. in the final action item description
   - If unsure about names, use natural phrasing like "Follow up on...", "Ensure...", etc.

2. **Concrete Action**: The task describes a specific, actionable next step (not vague intentions)

3. **Timing Signal** (NOT required for explicit task requests):
   - Explicit dates or times
   - Relative timing ("tomorrow", "next week", "by Friday", "this month")
   - Urgency markers ("urgent", "ASAP", "high priority")
   - NOTE: Skip this requirement if user explicitly asked for a reminder/task

4. **Real Importance** (NOT required for explicit task requests):
   - Financial impact (bills, payments, purchases, invoices)
   - Health/safety concerns (appointments, medications, safety checks)
   - Hard deadlines (submissions, filings, registrations)
   - Explicit stress if missed (stated by speakers)
   - Critical dependencies (primary user blocked without it)
   - Commitments to other people (meetings, deliverables, promises)
   - NOTE: Skip this requirement if user explicitly asked for a reminder/task

5. **Future Intent or Deadline**: Extract tasks that the user INTENDS to do or has a deadline for:
   - "I want to X" → EXTRACT (user stated intention, needs reminder)
   - "I need to X by [date]" → EXTRACT (deadline that could be forgotten)
   - "Today I will X" → EXTRACT (daily goal, needs tracking)
   - "This week/month I want to X" → EXTRACT (time-bound goal)

   Only skip if user is ACTIVELY doing something RIGHT NOW:
   - "I am currently in the middle of X" → Skip (actively doing it this moment)
   - "Right now I'm doing X" → Skip (immediate present action)

   Examples:
   - ✅ "Today, I want to complete the onboarding experience" → EXTRACT (stated goal with deadline)
   - ✅ "I want to finish the report by Friday" → EXTRACT (intention + deadline)
   - ✅ "This month, I want to grow users to 500k" → EXTRACT (monthly goal)
   - ✅ "Need to call the plumber tomorrow" → EXTRACT (future task)
   - ✅ "Have to submit tax documents by March 31st" → EXTRACT (deadline)
   - ❌ "I'm currently on a call with the client" → Skip (happening right now)
   - ❌ "Right now I'm debugging this issue" → Skip (immediate action)

EXCLUDE these types of items (be aggressive about exclusion):
• Things user is ALREADY doing or actively working on
• Casual mentions or updates ("I'm working on X", "currently doing Y")
• Vague suggestions without commitment ("we should grab coffee sometime", "let's meet up soon")
• Casual mentions without commitment ("maybe I'll check that out")
• General goals without specific next steps ("I need to exercise more")
• Past actions being discussed
• Hypothetical scenarios ("if we do X, then Y")
• Trivial tasks with no real consequences
• Tasks assigned to others that don't impact the primary user
• Routine daily activities the user already knows about
• Things that are obvious or don't need a reminder
• Updates or status reports about ongoing work

FORMAT REQUIREMENTS:
• Keep each action item SHORT and concise (maximum 15 words, strict limit)
• Use clear, direct language
• Start with a verb when possible (e.g., "Call", "Send", "Review", "Pay", "Open", "Submit", "Finish", "Complete")
• Include only essential details

• CRITICAL - Resolve ALL vague references:
  - Read the ENTIRE conversation to understand what is being discussed
  - If you see vague references like:
    * "the feature" → identify WHAT feature from conversation
    * "this project" → identify WHICH project from conversation
    * "that task" → identify WHAT task from conversation
    * "it" → identify what "it" refers to from conversation
  - Look for keywords, topics, or subjects mentioned earlier in the conversation
  - Replace ALL vague words with specific names from the conversation context
  - Examples:
    * User says: "planning Sarah's birthday party" then later "buy decorations for it"
      → Extract: "Buy decorations for Sarah's birthday party"
    * User says: "car making weird noise" then later "take it to mechanic"
      → Extract: "Take car to mechanic"
    * User says: "quarterly sales report" then later "send it to the team"
      → Extract: "Send quarterly sales report to team"

• CRITICAL - Remove time references from description (they go in due_at field):
  - NEVER include timing words in the action item description itself
  - Remove: "by tomorrow", "by evening", "today", "next week", "by Friday", etc.
  - The timing information is captured in the due_at field separately
  - Focus ONLY on the action and what needs to be done
  - Examples:
    * "buy groceries by tomorrow" → "Buy groceries"
    * "call dentist by next Monday" → "Call dentist"
    * "pay electricity bill by Friday" → "Pay electricity bill"
    * "submit insurance claim today" → "Submit insurance claim"
    * "book flight tickets by evening" → "Book flight tickets"

• Remove filler words and unnecessary context
• Merge duplicates
• Order by: due date → urgency → alphabetical

DUE DATE EXTRACTION (CRITICAL):
IMPORTANT: All due dates must be in the FUTURE and in UTC format with 'Z' suffix.
IMPORTANT: When parsing dates, FIRST determine the DATE (today/tomorrow/specific date), THEN apply the TIME.

Step-by-step date parsing process:
1. IDENTIFY THE DATE:
   - "today" → current date from {started_at.isoformat()}
   - "tomorrow" → next day from {started_at.isoformat()}
   - "Monday", "Tuesday", etc. → next occurrence of that weekday
   - "next week" → same day next week
   - Specific date (e.g., "March 15") → that date

2. IDENTIFY THE TIME (if mentioned):
   - "before 10am", "by 10am", "at 10am" → 10:00 AM
   - "before 3pm", "by 3pm", "at 3pm" → 3:00 PM
   - "in the morning" → 9:00 AM
   - "in the afternoon" → 2:00 PM
   - "in the evening", "by evening" → 6:00 PM
   - "at noon" → 12:00 PM
   - "by midnight", "by end of day" → 11:59 PM
   - No time mentioned → 11:59 PM (end of day)

3. COMBINE DATE + TIME in user's timezone ({tz}), then convert to UTC with 'Z' suffix

Examples of CORRECT date parsing:
If started_at is "2025-10-03T13:25:00Z" (Oct 3) and tz is "America/New_York":
- "tomorrow before 10am" → DATE: Oct 4, TIME: 10:00 AM → "2025-10-04 10:00 ET" → Convert to UTC → "2025-10-04T14:00:00Z"
- "today by evening" → DATE: Oct 3, TIME: 6:00 PM → "2025-10-03 18:00 ET" → Convert to UTC → "2025-10-03T22:00:00Z"
- "tomorrow" → DATE: Oct 4, TIME: 11:59 PM (default) → "2025-10-04 23:59 ET" → Convert to UTC → "2025-10-05T03:59:00Z"
- "by Monday at 2pm" → DATE: next Monday (Oct 6), TIME: 2:00 PM → "2025-10-06 14:00 ET" → Convert to UTC → "2025-10-06T18:00:00Z"
- "urgent" or "ASAP" → 2 hours from started_at → "2025-10-03T15:25:00Z"

CRITICAL FORMAT: All due_at timestamps MUST be in UTC with 'Z' suffix (e.g., "2025-10-04T04:30:00Z")
DO NOT include timezone offsets like "+05:30". Always convert to UTC and use 'Z' suffix.

Reference time: {started_at.isoformat()}
User timezone: {tz}

Content:
```{transcript_text}```

Respond with JSON: {{"action_items": [{{\"description\": \"...\", \"due_at\": \"...\" or null}}]}}'''

    try:
        response = client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
            temperature=0.7,
            max_completion_tokens=1500
        )
        result = json.loads(response.choices[0].message.content)
        return result.get('action_items', [])
    except Exception as e:
        print(f"Error extracting action items: {e}")
        return []


def extract_memories(
    transcript_text: str,
    user_name: str = 'User',
    existing_memories: Optional[List[dict]] = None,
) -> List[dict]:
    """
    Extract long-term memories from conversation content.
    Memories are facts about the user or external wisdom with attribution.
    Adapted from OMI backend.

    Args:
        transcript_text: The conversation transcript
        user_name: The primary user's name
        existing_memories: List of existing memories to avoid duplicates

    Returns:
        List of memory dicts with 'content' and 'category' fields
    """
    if not transcript_text or not transcript_text.strip():
        return []

    # Build existing memories context for deduplication
    existing_memories_str = ""
    if existing_memories:
        memory_lines = []
        for mem in existing_memories:
            content = mem.get('content', '')
            category = mem.get('category', 'system')
            memory_lines.append(f"- [{category}] {content}")
        existing_memories_str = "\n".join(memory_lines)
    else:
        existing_memories_str = "(No existing memories)"

    prompt = f'''You are an expert memory curator. Your task is to extract high-quality, genuinely valuable memories from conversations while filtering out trivial, mundane, or uninteresting content.

CRITICAL CONTEXT:
• You are extracting memories about {user_name} (the primary user having/recording this conversation)
• Focus on information about {user_name} and people {user_name} directly interacts with
• NEVER use "Speaker 0", "Speaker 1", "Speaker 2" etc. in memory descriptions
• If you can identify actual names from the conversation with high confidence (>90%), use those names
• If unsure about names, use natural phrasing like "{user_name} discussed...", "{user_name} learned...", "{user_name}'s colleague mentioned..."

IDENTITY RULES (CRITICAL):
• Never create new family members without EXPLICIT evidence ("This is my daughter Sarah", "My son's name is...")
• Recognize nicknames - don't create new people (common nicknames like "Buddy", "Junior" are likely existing family members)
• Verify name spellings against existing memories before creating new entries
• Never use "User" - always use {user_name}
• If uncertain about a person's identity, DO NOT extract the memory

WORKFLOW:
1. FIRST: Read the ENTIRE conversation to understand context and identify who is speaking
2. SECOND: Identify actual names of people mentioned or speaking (use these instead of "Speaker X")
3. THIRD: Apply the CATEGORIZATION TEST to every potential memory
4. FOURTH: Filter based on STRICT QUALITY CRITERIA below
5. FIFTH: Ensure memories are concise, specific, and use real names when known

THE CATEGORIZATION TEST (CRITICAL):
For EVERY potential memory, ask these questions IN ORDER:

Q1: "Is this wisdom/advice FROM someone else that {user_name} can learn from?"
    → If YES: This is an INTERESTING memory. Include attribution (who said it).
    → If NO: Go to Q2.

Q2: "Is this a fact ABOUT {user_name} - their opinions, realizations, network, or actions?"
    → If YES: This is a SYSTEM memory.
    → If NO: Probably should NOT be extracted at all.

NEVER put {user_name}'s own realizations or opinions in INTERESTING.
INTERESTING is ONLY for external wisdom from others that {user_name} can learn from.

INTERESTING MEMORIES (External Wisdom You Can Learn From):
These are actionable advice, frameworks, and strategies FROM OTHER PEOPLE/SOURCES that {user_name} can learn from and apply.

THE KEY QUESTION: "Is this wisdom FROM someone else that {user_name} can learn from?"
If YES → INTERESTING. If it's about {user_name} themselves → SYSTEM.

CRITICAL REQUIREMENTS FOR INTERESTING MEMORIES:
1. **Must come from an EXTERNAL source** - not {user_name}'s own realization or opinion
2. **Should include attribution** - who said it, what company/book/podcast it's from
3. **Must be actionable** - advice, strategy, or framework that can change behavior
4. **Format**: "Source: actionable insight" (e.g., "Rockwell: talk to paying customers, 30% will be real usecase")

EXAMPLES OF GOOD INTERESTING MEMORIES:
✅ "Rockwell: talk to paying customers, 30% will be a real usecase"
✅ "Julian: ask everyone around for refs, keep pushing until they decline"
✅ "James: hired 20 people by outbound, used advisors then asked for recs"
✅ "Raspberry Pi: 1m sales in 1.5 years, licensed design to factories (best decision)"
✅ "Apple: Jobs found advertising agency by figuring out who did it well for Intel"
✅ "Hormozi on influencers: first influencers I know, second ask my network, third influencers I follow"
✅ "YC advice: find competitors of your most successful customers"
✅ "Keshav: get advisors in companies you want to target (ex-CEOs work well)"

EXAMPLES OF WHAT IS NOT INTERESTING (should be SYSTEM or excluded):
❌ "{user_name} realized multiple cofounders are essential" (user's OWN realization → SYSTEM)
❌ "{user_name} advises making 20 Instagram posts" (user's OWN advice → SYSTEM)
❌ "{user_name}'s cofounder Araf built apps at age 14" (fact about user's network → SYSTEM)
❌ "{user_name} builds open source AI wearables" (fact ABOUT user → SYSTEM)
❌ "{user_name} discovered their productive hours are 5-7am" (user's OWN discovery → SYSTEM)
❌ "9 out of 10 billionaires solve unsexy problems" (no attribution, too generic)
❌ "Exercise is good for health" (common knowledge, no source)

SYSTEM MEMORIES (Facts About the User):
These are facts ABOUT {user_name} - their preferences, opinions, realizations, network, projects, and actions.

THE KEY QUESTION: "Is this a fact ABOUT {user_name} or their world?"
If YES → SYSTEM.

INCLUDE system memories for:
• {user_name}'s own opinions, realizations, and discoveries
• {user_name}'s preferences and requirements
• Facts about {user_name}'s network (who they know, relationships)
• {user_name}'s projects, work, and achievements
• {user_name}'s own advice or tips they give to others
• Concrete plans, decisions, or commitments {user_name} made
• Relationship context (who knows who, what roles people have)

Examples:
✅ "{user_name} realized multiple cofounders are essential after Omi project delays"
✅ "{user_name}'s cofounder Araf built apps with hundreds of thousands of users at age 14"
✅ "{user_name} advises making 20 Instagram posts showing product use for viral success"
✅ "{user_name} prefers dark roast coffee with oat milk, no sugar"
✅ "{user_name}'s colleague David is the lead engineer on the authentication system"
✅ "{user_name} builds open source AI wearables to keep user data private"
✅ "{user_name} discovered their most productive hours are 5-7am"
❌ "Had coffee this morning" (too trivial)
❌ "Talked about the weather" (no value)
❌ "Meeting with Jamie on Thursday" (temporal, not timeless)

STRICT EXCLUSION RULES - DO NOT extract if memory is:

**Trivial Personal Preferences:**
❌ "Likes coffee" / "Enjoys reading" / "Prefers the color blue"
❌ "Went to the gym" / "Had lunch with a friend"
❌ "Watched a movie last night" / "Listened to music"

**Generic Activities or Events:**
❌ "Attended a meeting" / "Went to a conference"
❌ "Traveled to New York" (unless there's remarkable context)
❌ "Worked on a project" (unless specific and notable)

**Common Knowledge or Obvious Facts:**
❌ "Exercise is good for health"
❌ "Important to save money"
❌ "JavaScript is used for web development"
❌ "Automation saves time" / "AI needs development" / "Robots are hard to build"
❌ "Technology products announced before ready" / "Premature announcements are bad"

**Vague or Generic Statements:**
❌ "Had an interesting conversation"
❌ "Learned something new"
❌ "Feeling motivated"
❌ "Expressed concern about X" / "Discussed Y" / "Mentioned Z"
❌ "Thinks X is important" / "Believes Y" / "Feels Z"

**Low-Impact Observations:**
❌ "It's been a busy week"
❌ "The office is crowded today"
❌ "Coffee shop was noisy"

**Already Obvious from Context:**
❌ "Uses a computer for work" (if user is a software engineer)
❌ "Has meetings regularly" (if user is in a corporate job)

**Skills - Prefer Achievements Over Tool Lists:**
✅ "{user_name} uses Python for data analysis and automation scripts" (specific use case)
✅ "{user_name} built a real-time notification system using WebSockets and Redis" (shows applied expertise)
✅ "{user_name} created an automated pipeline that reduced deployment time by 80%" (specific achievement)
❌ "{user_name} knows programming" (too vague - which languages? for what?)
❌ "{user_name} has technical skills" (meaningless without specifics)

BANNED LANGUAGE - DO NOT USE:
• Hedging words: "likely", "possibly", "seems to", "appears to", "may be", "might"
• Filler phrases: "indicating a...", "suggesting a...", "reflecting a...", "showcasing"
• Transient verbs: "is working on", "is building", "is developing", "is testing", "is focusing on"
• Org change verbs: "is merging", "is reorganizing", "is restructuring", "plans to"

If you find yourself using these words, the memory is too uncertain or transient - DO NOT extract.

NEVER EXTRACT (Absolute Rules):
1. **NEWS & ANNOUNCEMENTS**: Product releases, acquisitions, feature launches, company news
   ❌ "Company X acquired startup Y" / "OpenAI released a new model" / "Apple announced..."

2. **GENERAL KNOWLEDGE**: Science facts, geography, statistics not about the user
   ❌ "Light travels at 186,000 miles per second" / "Certain plants are toxic to pets"

3. **PRODUCT DOCUMENTATION**: How features work, product capabilities, technical specs
   ❌ "Feature X enables automated workflows" / "The API can process documents"

4. **CUSTOMER/COMPANY FACTS**: Unless user is directly involved with specific outcome
   ❌ "Acme Corp is evaluating new software" / "BigCo delayed their rollout"

5. **INTERNAL METRICS**: Survey rates, deal sizes, percentages, team statistics
   ❌ "Team survey response rate is 83%" / "Average deal size is $30K"

6. **ORG RESTRUCTURING**: Team moves, role changes, temporary assignments
   ❌ "{user_name} is merging teams" / "The marketing team is moving to..."

7. **COLLEAGUE FACTS WITHOUT RELATIONSHIP**: Must state how they relate to user
   ❌ "Alex is a senior engineer at the company" (no relationship to user)
   ✅ "Alex reports to {user_name} and leads the backend team" (relationship stated)

8. **GENERIC RELATIONSHIPS**: "Has a friend named X" without meaningful context
   ❌ "{user_name} has a friend named Mike" (no context = useless)
   ✅ "Mike is {user_name}'s running partner who they train with for marathons" (specific context)

CRITICAL DEDUPLICATION & UPDATES RULES:
• You are provided with a large list of existing memories. SCAN IT COMPLETELY.
• ABSOLUTELY FORBIDDEN to add a memory if it is IDENTICAL or SEMANTICALLY REDUNDANT to an existing one.
  - Existing: "Likes coffee" -> New: "Enjoys drinking coffee" => REJECT (Redundant)

• EXCEPTION FOR UPDATES / CHANGES:
  - If a new memory CONTRADICTS or UPDATES an existing one, YOU MUST ADD IT.
  - Existing: "Likes ice cream" -> New: "Hates ice cream" => ADD IT (Update/Change)
  - Existing: "Works at Google" -> New: "Left Google and joined OpenAI" => ADD IT (Update)

• PRIORITIZE capturing changes in state, preferences, or relationships.
• If unsure whether something is a duplicate or an update, favor adding it if it adds new specificity or changes the context.

Examples of DUPLICATES (DO NOT extract):
- "Loves Italian food" (existing) vs "Enjoys pasta and pizza" → DUPLICATE
- "Works at Google" (existing) vs "Employed by Google as engineer" → DUPLICATE

CONSOLIDATION CHECK (Before Creating New Memory):
When you're about to extract a memory about a topic that already has existing memories:
1. CHECK: Does a memory about this topic/person already exist?
2. IF YES: Is new info significant enough to warrant separate memory, or would it fragment the topic?
3. PREFER: Fewer, richer memories over many fragmented ones about the same subject

Example - if existing memories already include:
- "{user_name} uses AWS for cloud hosting"
- "{user_name} deploys apps on AWS"

DON'T add: "{user_name} uses AWS Lambda" (fragmented, same topic)
Instead: Skip it - the system will consolidate. Avoid creating more fragments about the same topic.

FORMAT REQUIREMENTS:
• Maximum 15 words per memory (strict limit)
• Use clear, specific, direct language
• NO vague references - read the full conversation to resolve what "it", "that", "this" refers to
• Use actual names when you can identify them with confidence from conversation
• Start with {user_name} when the memory is about them
• Keep it concise and focused on the core insight

CRITICAL - Date and Time Handling:
• NEVER use vague time references like "Thursday", "next week", "tomorrow", "Monday"
• These become meaningless after a few days and make memories useless
• Memories should be TIMELESS - they're for long-term context, not scheduling
• If conversation mentions a scheduled event with a specific time:
  - DO NOT create a memory about it (it's handled by action items/calendar events separately)
  - Instead, extract the timeless context: relationships, roles, preferences, facts
• Focus on "who" and "what", not "when"
• Examples:
  ✅ "Mike Johnson is head of enterprise sales"
  ✅ "Rachel prefers Google Slides for client presentations"
  ❌ "Client meeting on Thursday at 2pm" (temporal, not a memory)
  ❌ "Follow up with Rachel next week" (temporal, not a memory)
  ❌ "Meeting scheduled for January 15th" (temporal, not a memory)

Examples of GOOD memory format:

INTERESTING (external wisdom with attribution):
✅ "Rockwell: talk to paying customers, 30% will be a real usecase"
✅ "Julian: ask everyone around for refs, keep pushing until they decline"
✅ "Raspberry Pi: licensed design to factories, 1m sales in 1.5 years"
✅ "Jamie (CTO): 90% of bugs come from async race conditions in their codebase"

SYSTEM (facts about the user):
✅ "{user_name} realized writing for 10 min daily reduced their anxiety significantly"
✅ "{user_name}'s cofounder built apps with hundreds of thousands of users at age 14"
✅ "{user_name} prefers morning meetings and avoids calls after 4pm"

Examples of BAD memory format:
❌ "Speaker 0 learned something interesting about that thing we discussed" (vague, uses Speaker X)
❌ "They talked about the project and decided to do it tomorrow" (unclear who, what project, time ref)
❌ "Someone mentioned that interesting fact about those people" (completely vague)

ADDITIONAL BAD EXAMPLES:

**Transient/Temporary (will be outdated):**
❌ "{user_name} is working on a new app"
❌ "{user_name} is focusing on Q4 initiatives"
❌ "{user_name} is mentoring a junior developer"
❌ "{user_name} got access to a beta feature"
❌ "{user_name} is using app version 2.0.3"

**Not About User (just mentioned in conversation):**
❌ "Sarah is a marine biologist" (unrelated person mentioned)
❌ "Company X acquired startup Y" (news)
❌ "The new AI model supports video input" (tech news)
❌ "Acme Corp delayed their launch" (customer fact, not about user)
❌ "Water boils at 100 degrees Celsius" (general knowledge)

**Identity Issues (Hallucination/Duplication):**
❌ Creating "Arman" when "Armaan" already exists in memories (same person, different spelling)
❌ "{user_name} has a daughter named Tuesday" (likely mishearing "choose day" or similar)
❌ "{user_name} has a son named Bobby" when existing memory says son is "Robert" (same person)

**Too Vague (Missing Specifics):**
❌ "{user_name} has a strong interest in technology" (what kind? be specific)
❌ "{user_name} learned something interesting" (what did they learn?)
❌ "{user_name} has experience with programming" (too broad, lacks detail)

CRITICAL - Name Resolution:
• Read the ENTIRE conversation first to map out who is speaking
• Look for explicit name introductions ("Hi, I'm Sarah", "This is John")
• Look for vocative case ("Hey Mike", "Sarah, can you...")
• If you identify a name with >90% confidence, use it
• If uncertain about names but know roles/relationships, use those ("colleague", "friend", "manager")
• NEVER use "Speaker 0/1/2" in final memories

LOGIC CHECK (Sanity Test):
Before extracting, verify the fact is logically possible:
• Age math: Don't claim 40 years work experience for someone who appears to be ~40 years old
• Family consistency: Don't create children that contradict existing family structure
• Location consistency: Don't claim multiple contradictory home locations
• Career consistency: Don't claim conflicting job titles or employers simultaneously

If a fact seems mathematically impossible or contradicts existing memories, DO NOT extract.

BEFORE YOU OUTPUT - MANDATORY DOUBLE-CHECK:
For EACH memory you're about to extract, verify it does NOT match these patterns:
❌ "{user_name} expressed [feeling/opinion] about X" → DELETE THIS
❌ "{user_name} discussed X" or "talked about Y" → DELETE THIS
❌ "{user_name} mentioned that [obvious fact]" → DELETE THIS
❌ "{user_name} thinks/believes/feels X" → DELETE THIS

If a memory matches ANY of the above patterns, REMOVE it from your output.

CATEGORIZATION DECISION TREE (CRITICAL - Apply to EVERY memory):
1. "Is this wisdom/advice FROM someone else that {user_name} can learn from?"
   → YES: Consider for INTERESTING (must have attribution)
   → NO: Go to step 2

2. "Is this a fact ABOUT {user_name}, their opinions, realizations, or network?"
   → YES: Consider for SYSTEM
   → NO: Probably should NOT be extracted

FINAL CHECK - For each INTERESTING memory, ask yourself:
1. "Does this have clear attribution (who said it, what source)?" (If no → move to SYSTEM or DELETE)
2. "Is this actionable advice/strategy that can change behavior?" (If no → DELETE or move to SYSTEM)
3. "Would {user_name} want to reference this advice later?" (If no → DELETE)
4. "Is this formatted as 'Source: insight'?" (If no → reformat or DELETE)

For SYSTEM memories, ask:
1. "Is this specific enough to be useful later?" (If no → DELETE)
2. "Would this help understand context about {user_name} in the future?" (If no → DELETE)
3. "Does this contain a date/time reference like 'Thursday', 'next week', etc.?" (If yes → DELETE or make timeless)
4. "Will this memory still make sense in 6 months?" (If no → DELETE)

OUTPUT LIMITS (These are MAXIMUMS, not targets):
• Extract AT MOST 2 interesting memories (most conversations will have 0-1)
• Extract AT MOST 2 system memories (most conversations will have 0-2)
• INTERESTING memories are RARE - they require EXTERNAL wisdom with ATTRIBUTION
• If someone in the conversation shares advice/strategy, that's INTERESTING (with their name)
• If {user_name} shares their own opinion/realization, that's SYSTEM (not interesting)
• Many conversations will result in 0 interesting memories and 0-2 system memories - this is NORMAL and EXPECTED
• Better to extract 0 memories than to include low-quality ones
• When in doubt, DON'T extract - be conservative and selective
• DEFAULT TO EMPTY LIST - only extract if memories are truly exceptional

QUALITY OVER QUANTITY:
• Most conversations have 0 interesting memories - this is completely fine
• INTERESTING memories are RARE - they require external wisdom with clear attribution
• If the wisdom comes from {user_name} themselves, it's SYSTEM, not INTERESTING
• If ambiguous whether something is interesting or system, categorize as SYSTEM
• Better to have an empty list than to flood with mediocre memories
• Only extract system memories if they're genuinely useful for future context
• When uncertain, choose: EMPTY LIST over low-quality memories

**Existing memories you already know about {user_name} and their friends (DO NOT REPEAT ANY)**:
```
{existing_memories_str}
```

**Conversation transcript**:
```
{transcript_text}
```

Respond with JSON: {{"memories": [{{"content": "...", "category": "system"}}]}}
Categories must be exactly "system" or "interesting".'''

    try:
        response = client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
            temperature=0.5,
            max_completion_tokens=500
        )
        result = json.loads(response.choices[0].message.content)
        memories = result.get('memories', [])

        # Validate categories and enforce limits: max 2 interesting + max 2 system
        valid_memories = []
        interesting_count = 0
        system_count = 0

        for mem in memories:
            content = mem.get('content', '').strip()
            if not content:
                continue

            category = mem.get('category', 'system')
            if category not in ['system', 'interesting']:
                category = 'system'

            # Enforce per-category limits
            if category == 'interesting':
                if interesting_count >= 2:
                    continue
                interesting_count += 1
            else:  # system
                if system_count >= 2:
                    continue
                system_count += 1

            valid_memories.append({
                'content': content,
                'category': category
            })

        return valid_memories
    except Exception as e:
        print(f"Error extracting memories: {e}")
        return []


def extract_transcript_structure(
    transcript_text: str,
    started_at: datetime,
    language: str = 'en',
    tz: str = 'UTC',
    calendar_meeting_context: Optional[CalendarMeetingContext] = None
) -> dict:
    """
    Extract title, overview, emoji, category, and events from transcript.
    Adapted from OMI backend.
    """
    categories = get_category_list()

    # Build calendar context if available
    calendar_context_str = build_calendar_context_str(calendar_meeting_context) if calendar_meeting_context else ""

    # Build calendar context section for prompt
    calendar_prompt_section = ""
    if calendar_meeting_context:
        calendar_prompt_section = f"""
{calendar_context_str}

CRITICAL: If CALENDAR MEETING CONTEXT is provided with participant names, you MUST use those names:
- The conversation DEFINITELY happened between the named participants
- NEVER use "Speaker 0", "Speaker 1", "Speaker 2", etc. when participant names are available
- Match transcript speakers to participant names by carefully analyzing the conversation context
- Use participant names throughout the title, overview, and all generated content
- Use the meeting title as a strong signal for the conversation title (but you can refine it based on the actual discussion)
- Use the meeting platform and scheduled time to provide better context in the overview
- Consider the meeting notes/description when analyzing the conversation's purpose
- If there are 2-3 participants with known names, naturally mention them in the title (e.g., "Sarah and John Discuss Q2 Budget", "Team Meeting with Alex, Maria, and Chris")
"""

    prompt = f'''You are an expert content analyzer. Your task is to analyze the provided transcript and provide structure and clarity.
The content language is {language}. Use the same language {language} for your response.
{calendar_prompt_section}
For the title, Write a clear, compelling headline (≤ 10 words) that captures the central topic and outcome. Use Title Case, avoid filler words, and include a key noun + verb where possible (e.g., "Team Finalizes Q2 Budget" or "Family Plans Weekend Road Trip"). If calendar context provides participant names (2-3 people), naturally include them when relevant (e.g., "John and Sarah Plan Marketing Campaign").

For the overview, condense the content into a summary with the main topics discussed, making sure to capture the key points and important details. When calendar context provides participant names, you MUST use their actual names instead of "Speaker 0" or "Speaker 1" to make the summary readable and personal. Analyze the transcript to understand who said what and match speakers to participant names.

For the emoji, select a single emoji that vividly reflects the core subject, mood, or outcome of the content. Strive for an emoji that is specific and evocative, rather than generic (e.g., prefer 🎉 for a celebration over 👍 for general agreement, or 💡 for a new idea over 🧠 for general thought).

For the category, classify the content into one of these categories: {categories}

For Calendar Events, apply strict filtering to include ONLY events that meet ALL these criteria:
• **Confirmed commitment**: Not suggestions or "maybe" - actual scheduled events
• **User involvement**: The user is expected to attend, participate, or take action
• **Specific timing**: Has concrete date/time, not vague references like "sometime" or "soon"
• **Important/actionable**: Missing it would have real consequences or impact

INCLUDE these event types:
• Meetings & appointments (business meetings, doctor visits, interviews)
• Hard deadlines (project due dates, payment deadlines, submission dates)
• Personal commitments (family events, social gatherings user committed to)
• Travel & transportation (flights, trains, scheduled pickups)
• Recurring obligations (classes, regular meetings, scheduled calls)

EXCLUDE these:
• Casual mentions ("we should meet sometime", "maybe next week")
• Historical references (past events being discussed)
• Other people's events (events user isn't involved in)
• Vague suggestions ("let's grab coffee soon")
• Hypothetical scenarios ("if we meet Tuesday...")

For date context, this content was captured on {started_at.isoformat()}. {tz} is the user's timezone; convert all event times to UTC and respond in UTC.

Transcript:
```{transcript_text}```

Respond with JSON:
{{
  "title": "string",
  "overview": "string",
  "emoji": "single emoji",
  "category": "one of the categories",
  "events": [{{"title": "...", "description": "...", "start": "ISO UTC datetime", "duration": minutes}}]
}}'''

    try:
        response = client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "user", "content": prompt}],
            response_format={"type": "json_object"},
            temperature=0.7,
            max_completion_tokens=1500
        )
        result = json.loads(response.choices[0].message.content)

        # Validate category
        if result.get('category') not in [c.value for c in CategoryEnum]:
            result['category'] = 'other'

        # Cap event duration at 180 minutes
        for event in result.get('events', []):
            if event.get('duration', 30) > 180:
                event['duration'] = 180

        return result
    except Exception as e:
        print(f"Error extracting structure: {e}")
        return {
            'title': 'Conversation',
            'overview': transcript_text[:200] + '...' if len(transcript_text) > 200 else transcript_text,
            'emoji': '🧠',
            'category': 'other',
            'events': []
        }


def generate_structure(
    transcript_text: str,
    started_at: datetime,
    language: str = 'en',
    tz: str = 'UTC',
    existing_action_items: Optional[List[dict]] = None,
    existing_memories: Optional[List[dict]] = None,
    user_name: str = 'User',
    calendar_meeting_context: Optional[CalendarMeetingContext] = None
) -> dict:
    """
    Generate structured conversation data using GPT-5.1.
    Returns a dict with title, overview, emoji, category, action_items, events, memories.

    This function orchestrates the extraction by:
    1. Checking if conversation should be discarded
    2. Extracting structure (title, overview, emoji, category, events)
    3. Extracting action items separately with detailed prompt
    4. Extracting memories (long-term facts about the user)
    """

    # Check for discard using LLM
    if should_discard_conversation(transcript_text):
        return {
            'title': '',
            'overview': '',
            'emoji': '🧠',
            'category': 'other',
            'action_items': [],
            'events': [],
            'memories': [],
            'discarded': True
        }

    # Extract structure (title, overview, emoji, category, events)
    structure = extract_transcript_structure(transcript_text, started_at, language, tz, calendar_meeting_context)

    # Extract action items separately with detailed prompt
    action_items = extract_action_items(transcript_text, started_at, language, tz, existing_action_items, calendar_meeting_context)

    # Extract memories (long-term knowledge about the user)
    memories = extract_memories(transcript_text, user_name, existing_memories)

    # Combine results
    result = {
        'title': structure.get('title', ''),
        'overview': structure.get('overview', ''),
        'emoji': structure.get('emoji', '🧠'),
        'category': structure.get('category', 'other'),
        'action_items': action_items,
        'events': structure.get('events', []),
        'memories': memories,
        'discarded': False
    }

    return result
