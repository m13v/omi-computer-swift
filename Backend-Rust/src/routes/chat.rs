// Chat Context Routes - Context retrieval for RAG
// Ported from Python backend: utils/retrieval/graph.py, utils/llm/chat.py
//
// Endpoints:
// - POST /v2/chat-context - Get context for building chat prompts

use axum::{
    extract::State,
    http::StatusCode,
    routing::post,
    Json, Router,
};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use std::sync::Arc;

use crate::auth::AuthUser;
use crate::llm::LlmClient;
use crate::services::FirestoreService;
use crate::AppState;

// ============================================================================
// REQUEST/RESPONSE MODELS
// ============================================================================

/// Request for chat context
#[derive(Debug, Deserialize)]
pub struct ChatContextRequest {
    /// The user's question/message
    pub question: String,
    /// User's timezone (e.g., "America/Los_Angeles")
    #[serde(default = "default_timezone")]
    pub timezone: String,
    /// Optional app ID for app-specific context (TODO: wire up to get_chat_session)
    #[serde(default, rename = "app_id")]
    pub _app_id: Option<String>,
    /// Previous messages for context (TODO: implement conversation history)
    #[serde(default, rename = "messages")]
    pub _messages: Vec<ChatMessageInput>,
}

fn default_timezone() -> String {
    "UTC".to_string()
}

#[derive(Debug, Deserialize)]
pub struct ChatMessageInput {
    #[serde(rename = "text")]
    pub _text: String,
    #[serde(rename = "sender")]
    pub _sender: String, // "human" or "ai"
}

/// Response with context for building prompts
#[derive(Debug, Serialize)]
pub struct ChatContextResponse {
    /// Whether context retrieval was needed
    pub requires_context: bool,
    /// Extracted date range from the question (if any)
    pub date_range: Option<DateRange>,
    /// Relevant conversations (summaries)
    pub conversations: Vec<ConversationSummary>,
    /// User memories/facts
    pub memories: Vec<MemorySummary>,
    /// Formatted context string ready for prompt injection
    pub context_string: String,
}

/// Request for initial message generation
#[derive(Debug, Deserialize)]
pub struct InitialMessageRequest {
    /// Session ID to associate the message with
    pub session_id: String,
    /// Optional app ID for app-specific persona
    #[serde(default)]
    pub app_id: Option<String>,
}

/// Response with generated initial message
#[derive(Debug, Serialize)]
pub struct InitialMessageResponse {
    /// The generated greeting message
    pub message: String,
    /// The message ID (saved to database)
    pub message_id: String,
}

/// Request for session title generation
#[derive(Debug, Deserialize)]
pub struct GenerateTitleRequest {
    /// Session ID to update
    pub session_id: String,
    /// Messages to analyze for title generation
    pub messages: Vec<TitleMessageInput>,
}

#[derive(Debug, Deserialize)]
pub struct TitleMessageInput {
    pub text: String,
    pub sender: String, // "human" or "ai"
}

/// Response with generated title
#[derive(Debug, Serialize)]
pub struct GenerateTitleResponse {
    /// The generated title
    pub title: String,
}

#[derive(Debug, Serialize)]
pub struct DateRange {
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct ConversationSummary {
    pub id: String,
    pub title: String,
    pub overview: String,
    pub emoji: String,
    pub category: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct MemorySummary {
    pub id: String,
    pub content: String,
    pub category: String,
}

// ============================================================================
// LLM PROMPTS (Ported from Python)
// ============================================================================

const REQUIRES_CONTEXT_PROMPT: &str = r#"
Based on the current question, determine whether the user is asking something that requires context from their past conversations or memories to answer properly.

Return true if the question:
- Asks about past events, conversations, or experiences
- References specific people, topics, or time periods
- Needs personal context to answer accurately
- Asks "what did I...", "when did I...", "who did I talk to about...", etc.

Return false if the question:
- Is a greeting (Hi, Hello, How are you?)
- Is a general knowledge question
- Is a simple task request that doesn't need history
- Can be answered without any personal context

User's Question:
{question}
"#;

const DATE_EXTRACTION_PROMPT: &str = r#"
Extract the date range from the user's question that would help find relevant conversations.

Current date/time in UTC: {current_datetime}
User's timezone: {timezone}

Rules:
- "today" = start of today to end of today in user's timezone
- "yesterday" = start of yesterday to end of yesterday
- "this week" = start of this week (Monday) to now
- "last week" = previous week Monday to Sunday
- "X days ago" = that specific day
- "X hours ago" = narrow window around that time
- If no date reference, return null

User's Question:
{question}

Return the date range in UTC, or null if no date reference found.
"#;

// ============================================================================
// HANDLERS
// ============================================================================

/// POST /v2/chat-context - Get context for building chat prompts
async fn get_chat_context(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<ChatContextRequest>,
) -> Result<Json<ChatContextResponse>, StatusCode> {
    let question = request.question.trim();
    if question.is_empty() {
        return Ok(Json(ChatContextResponse {
            requires_context: false,
            date_range: None,
            conversations: vec![],
            memories: vec![],
            context_string: String::new(),
        }));
    }

    tracing::info!(
        "Getting chat context for user {} - question: {}",
        user.uid,
        &question[..question.len().min(50)]
    );

    // Get API key for LLM calls
    let api_key = match &state.config.gemini_api_key {
        Some(key) => key.clone(),
        None => {
            tracing::warn!("No Gemini API key configured, returning basic context");
            return get_basic_context(&state.firestore, &user.uid, &request).await;
        }
    };

    let llm = LlmClient::new(api_key);

    // Step 1: Determine if context is needed
    let requires_context = check_requires_context(&llm, question).await.unwrap_or(true);

    if !requires_context {
        tracing::info!("Question does not require context");
        // Still return memories for personalization
        let memories = get_user_memories(&state.firestore, &user.uid).await;
        let context_string = format_memories_context(&memories);

        return Ok(Json(ChatContextResponse {
            requires_context: false,
            date_range: None,
            conversations: vec![],
            memories,
            context_string,
        }));
    }

    // Step 2: Extract date range from question
    let date_range = extract_date_range(&llm, question, &request.timezone).await;
    tracing::info!("Extracted date range: {:?}", date_range);

    // Step 3: Fetch conversations (with date filter if available)
    let conversations = get_relevant_conversations(
        &state.firestore,
        &user.uid,
        date_range.as_ref(),
    ).await;

    // Step 4: Fetch user memories
    let memories = get_user_memories(&state.firestore, &user.uid).await;

    // Step 5: Build context string for prompt
    let context_string = build_context_string(&conversations, &memories);

    tracing::info!(
        "Chat context: {} conversations, {} memories",
        conversations.len(),
        memories.len()
    );

    Ok(Json(ChatContextResponse {
        requires_context: true,
        date_range,
        conversations,
        memories,
        context_string,
    }))
}

/// POST /v2/chat/initial-message - Generate personalized initial greeting
async fn generate_initial_message(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<InitialMessageRequest>,
) -> Result<Json<InitialMessageResponse>, StatusCode> {
    tracing::info!(
        "Generating initial message for user {} session {} (app_id={:?})",
        user.uid,
        request.session_id,
        request.app_id
    );

    // Get API key for LLM calls
    let api_key = match &state.config.gemini_api_key {
        Some(key) => key.clone(),
        None => {
            tracing::warn!("No Gemini API key configured, returning default greeting");
            // Save and return default greeting
            return save_and_return_greeting(
                &state,
                &user.uid,
                &request.session_id,
                request.app_id.as_deref(),
                "Hello! I'm here to help. What's on your mind?",
            )
            .await;
        }
    };

    let llm = LlmClient::new(api_key);

    // Fetch user memories (top 10)
    let memories: Vec<String> = match state.firestore.get_memories(&user.uid, 10).await {
        Ok(mems) => mems.into_iter().map(|m| m.content).collect(),
        Err(e) => {
            tracing::warn!("Failed to fetch memories for initial message: {}", e);
            vec![]
        }
    };

    // Get app persona if app_id provided
    let (app_name, app_persona) = if let Some(app_id) = &request.app_id {
        match state.firestore.get_app(&user.uid, app_id).await {
            Ok(Some(app)) => (Some(app.name), app.chat_prompt),
            Ok(None) => {
                tracing::warn!("App not found: {}", app_id);
                (None, None)
            }
            Err(e) => {
                tracing::warn!("Failed to fetch app: {}", e);
                (None, None)
            }
        }
    } else {
        (None, None)
    };

    // Generate personalized greeting
    let greeting = match llm
        .generate_initial_message(&memories, app_name.as_deref(), app_persona.as_deref())
        .await
    {
        Ok(msg) => msg.trim().to_string(),
        Err(e) => {
            tracing::error!("Failed to generate initial message: {}", e);
            "Hello! I'm here to help. What's on your mind?".to_string()
        }
    };

    // Save the greeting as an AI message and return
    save_and_return_greeting(
        &state,
        &user.uid,
        &request.session_id,
        request.app_id.as_deref(),
        &greeting,
    )
    .await
}

/// Helper to save greeting as AI message and return response
async fn save_and_return_greeting(
    state: &AppState,
    uid: &str,
    session_id: &str,
    app_id: Option<&str>,
    greeting: &str,
) -> Result<Json<InitialMessageResponse>, StatusCode> {
    match state
        .firestore
        .save_message(uid, greeting, "ai", app_id, Some(session_id))
        .await
    {
        Ok(message) => {
            // Update session with preview
            if let Err(e) = state
                .firestore
                .update_chat_session_with_message(uid, session_id, greeting, None)
                .await
            {
                tracing::warn!("Failed to update session preview: {}", e);
            }

            Ok(Json(InitialMessageResponse {
                message: greeting.to_string(),
                message_id: message.id,
            }))
        }
        Err(e) => {
            tracing::error!("Failed to save initial message: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// POST /v2/chat/generate-title - Generate a title for a chat session
async fn generate_session_title(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<GenerateTitleRequest>,
) -> Result<Json<GenerateTitleResponse>, StatusCode> {
    tracing::info!(
        "Generating title for user {} session {} ({} messages)",
        user.uid,
        request.session_id,
        request.messages.len()
    );

    // Get API key for LLM calls
    let api_key = match &state.config.gemini_api_key {
        Some(key) => key.clone(),
        None => {
            tracing::warn!("No Gemini API key configured, returning default title");
            return Ok(Json(GenerateTitleResponse {
                title: "New Chat".to_string(),
            }));
        }
    };

    let llm = LlmClient::new(api_key);

    // Convert messages to the format expected by the LLM
    let messages: Vec<(String, String)> = request
        .messages
        .iter()
        .map(|m| (m.text.clone(), m.sender.clone()))
        .collect();

    // Generate title
    let title = match llm.generate_session_title(&messages).await {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("Failed to generate session title: {}", e);
            "New Chat".to_string()
        }
    };

    // Update the session with the new title
    if let Err(e) = state
        .firestore
        .update_chat_session(&user.uid, &request.session_id, Some(&title), None)
        .await
    {
        tracing::warn!("Failed to update session title: {}", e);
    }

    tracing::info!("Generated title for session {}: {}", request.session_id, title);

    Ok(Json(GenerateTitleResponse { title }))
}

// ============================================================================
// HELPER FUNCTIONS
// ============================================================================

/// Check if the question requires context using LLM
async fn check_requires_context(llm: &LlmClient, question: &str) -> Result<bool, ()> {
    let prompt = REQUIRES_CONTEXT_PROMPT.replace("{question}", question);

    match llm.check_requires_context(&prompt).await {
        Ok(result) => Ok(result),
        Err(e) => {
            tracing::warn!("Failed to check requires_context: {}", e);
            // Default to requiring context on error
            Ok(true)
        }
    }
}

/// Extract date range from question using LLM
async fn extract_date_range(
    llm: &LlmClient,
    question: &str,
    timezone: &str,
) -> Option<DateRange> {
    let now = Utc::now();
    let prompt = DATE_EXTRACTION_PROMPT
        .replace("{question}", question)
        .replace("{current_datetime}", &now.to_rfc3339())
        .replace("{timezone}", timezone);

    match llm.extract_date_range(&prompt).await {
        Ok(Some((start, end))) => Some(DateRange { start, end }),
        Ok(None) => {
            // No date reference found - default to last 7 days
            Some(DateRange {
                start: now - Duration::days(7),
                end: now,
            })
        }
        Err(e) => {
            tracing::warn!("Failed to extract date range: {}", e);
            // Default to last 7 days on error
            Some(DateRange {
                start: now - Duration::days(7),
                end: now,
            })
        }
    }
}

/// Get relevant conversations from Firestore
async fn get_relevant_conversations(
    firestore: &Arc<FirestoreService>,
    uid: &str,
    date_range: Option<&DateRange>,
) -> Vec<ConversationSummary> {
    // Fetch recent completed conversations
    let statuses = vec!["completed".to_string()];

    match firestore
        .get_conversations(uid, 50, 0, false, &statuses, None, None, None, None)
        .await
    {
        Ok(conversations) => {
            // Filter by date range if provided
            let filtered: Vec<_> = if let Some(range) = date_range {
                conversations
                    .into_iter()
                    .filter(|c| c.created_at >= range.start && c.created_at <= range.end)
                    .take(20)
                    .collect()
            } else {
                conversations.into_iter().take(20).collect()
            };

            filtered
                .into_iter()
                .map(|c| ConversationSummary {
                    id: c.id,
                    title: c.structured.title,
                    overview: c.structured.overview,
                    emoji: c.structured.emoji,
                    category: format!("{:?}", c.structured.category),
                    created_at: c.created_at,
                })
                .collect()
        }
        Err(e) => {
            tracing::error!("Failed to fetch conversations: {}", e);
            vec![]
        }
    }
}

/// Get user memories from Firestore
async fn get_user_memories(firestore: &Arc<FirestoreService>, uid: &str) -> Vec<MemorySummary> {
    match firestore.get_memories(uid, 50).await {
        Ok(memories) => memories
            .into_iter()
            .map(|m| MemorySummary {
                id: m.id,
                content: m.content,
                category: format!("{:?}", m.category),
            })
            .collect(),
        Err(e) => {
            tracing::error!("Failed to fetch memories: {}", e);
            vec![]
        }
    }
}

/// Build a formatted context string for prompt injection
fn build_context_string(
    conversations: &[ConversationSummary],
    memories: &[MemorySummary],
) -> String {
    let mut parts = Vec::new();

    // Add memories section
    if !memories.is_empty() {
        let mut memory_lines = vec!["<user_facts>".to_string()];
        memory_lines.push("Facts about the user:".to_string());
        for (i, memory) in memories.iter().take(30).enumerate() {
            memory_lines.push(format!("{}. {}", i + 1, memory.content));
        }
        memory_lines.push("</user_facts>".to_string());
        parts.push(memory_lines.join("\n"));
    }

    // Add conversations section
    if !conversations.is_empty() {
        let mut conv_lines = vec!["<recent_conversations>".to_string()];
        conv_lines.push("Recent conversations for context:".to_string());
        for (i, conv) in conversations.iter().take(10).enumerate() {
            conv_lines.push(format!(
                "[{}] {} {} - {} ({})",
                i + 1,
                conv.emoji,
                conv.title,
                conv.overview,
                conv.created_at.format("%Y-%m-%d")
            ));
        }
        conv_lines.push("</recent_conversations>".to_string());
        parts.push(conv_lines.join("\n"));
    }

    parts.join("\n\n")
}

/// Format memories only for context (when no conversation context needed)
fn format_memories_context(memories: &[MemorySummary]) -> String {
    if memories.is_empty() {
        return String::new();
    }

    let mut lines = vec!["<user_facts>".to_string()];
    lines.push("Facts about the user:".to_string());
    for memory in memories.iter().take(30) {
        lines.push(format!("- {}", memory.content));
    }
    lines.push("</user_facts>".to_string());
    lines.join("\n")
}

/// Fallback: Get basic context without LLM calls
async fn get_basic_context(
    firestore: &Arc<FirestoreService>,
    uid: &str,
    _request: &ChatContextRequest,
) -> Result<Json<ChatContextResponse>, StatusCode> {
    let now = Utc::now();
    let date_range = DateRange {
        start: now - Duration::days(7),
        end: now,
    };

    let conversations = get_relevant_conversations(firestore, uid, Some(&date_range)).await;
    let memories = get_user_memories(firestore, uid).await;
    let context_string = build_context_string(&conversations, &memories);

    Ok(Json(ChatContextResponse {
        requires_context: true,
        date_range: Some(date_range),
        conversations,
        memories,
        context_string,
    }))
}

// ============================================================================
// ROUTER
// ============================================================================

pub fn chat_routes() -> Router<AppState> {
    Router::new()
        .route("/v2/chat-context", post(get_chat_context))
        .route("/v2/chat/initial-message", post(generate_initial_message))
        .route("/v2/chat/generate-title", post(generate_session_title))
}
