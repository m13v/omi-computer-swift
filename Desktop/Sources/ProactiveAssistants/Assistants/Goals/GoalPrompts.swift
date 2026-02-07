import Foundation

/// Prompts for AI-powered goal features
/// Adapted from backend: /Users/matthewdi/omi/backend/utils/llm/goals.py
enum GoalPrompts {

    /// Prompt for suggesting a goal based on user memories
    static let suggestGoal = """
Based on the user's memories and interests, suggest ONE meaningful personal goal they could track.

User's recent memories/learnings:
{memory_context}

Generate a goal suggestion in this exact JSON format:
{
    "suggested_title": "Brief, actionable goal title (e.g., 'Exercise 5 times a week', 'Read 20 books this year', 'Save $10,000')",
    "suggested_type": "scale" or "numeric" or "boolean",
    "suggested_target": <number>,
    "suggested_min": <minimum value>,
    "suggested_max": <maximum value or target>,
    "reasoning": "One sentence explaining why this goal fits the user"
}

Choose a goal type:
- "boolean" for yes/no goals (0 or 1)
- "scale" for rating goals (e.g., 0-10 satisfaction)
- "numeric" for countable goals (e.g., books read, money saved, users acquired)

Make the goal specific, measurable, and relevant to their interests.
"""

    /// Prompt for getting actionable advice on achieving a goal
    static let goalAdvice = """
You are a strategic advisor. Based on the user's goal and their context, give ONE specific actionable step they should take THIS WEEK.

GOAL: "{goal_title}"
PROGRESS: {current_value} / {target_value} ({progress_pct}%)

RECENT CONVERSATIONS (what they've been discussing/working on):
{conversation_context}

USER FACTS:
{memory_context}

Give ONE specific action in 1-2 sentences. Be concise but complete. No generic advice.
"""

    /// Prompt for automatically generating a goal based on rich user context
    static let generateGoal = """
Based on everything you know about this user, suggest ONE specific, measurable goal they should be working toward right now.

USER'S PERSONA:
{persona_context}

USER'S MEMORIES (facts about them):
{memory_context}

RECENT CONVERSATIONS (what they've been discussing/working on):
{conversation_context}

CURRENT TASKS (what they're tracking):
{action_items_context}

EXISTING GOALS (do NOT duplicate these):
{existing_goals}

Generate ONE new goal that:
1. Is specific and measurable with a clear numeric target
2. Is relevant to what the user actually cares about based on the evidence above
3. Does NOT duplicate any existing goal listed above
4. Picks something the user would find meaningful based on their conversations, tasks, and persona
5. Prefers goals with clear numeric targets (e.g., "Ship 3 features this month", "Read 2 books", "Close 5 deals")

Return JSON only:
{
    "suggested_title": "Brief, actionable goal title",
    "suggested_type": "scale" or "numeric" or "boolean",
    "suggested_target": <number>,
    "suggested_min": <minimum value>,
    "suggested_max": <maximum value or target>,
    "reasoning": "One sentence explaining why this goal fits the user right now"
}

Choose a goal type:
- "boolean" for yes/no goals (0 or 1)
- "scale" for rating goals (e.g., 0-10 satisfaction)
- "numeric" for countable goals (e.g., books read, money saved, users acquired)
"""

    /// Prompt for extracting goal progress from text
    static let extractProgress = """
Analyze this message to see if it mentions progress toward this goal:

Goal: "{goal_title}"
Goal Type: {goal_type}
Current Progress: {current_value} / {target_value}

User Message: "{text}"

If the message mentions a NEW progress value for this goal, extract it.
Handle formats like:
- "1k users" -> 1000
- "500k" -> 500000
- "1.5 million" -> 1500000
- "1000" -> 1000
- Percentages relative to goal

Return JSON only: {"found": true/false, "value": number_or_null, "reasoning": "brief explanation"}
Only return found=true if you're confident this is about the SPECIFIC goal mentioned above.
"""
}
