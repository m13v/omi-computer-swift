// Conversations routes - Port from Python backend
// Endpoints: GET /v1/conversations, POST /v1/conversations/from-segments

use axum::{
    extract::{Query, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use chrono::Utc;
use serde::Deserialize;

use crate::auth::AuthUser;
use crate::llm::LlmClient;
use crate::models::{
    Conversation, ConversationSource, ConversationStatus, CreateConversationRequest,
    CreateConversationResponse, Structured,
};
use crate::AppState;

#[derive(Deserialize)]
pub struct GetConversationsQuery {
    #[serde(default = "default_limit")]
    pub limit: usize,
    #[serde(default)]
    pub offset: usize,
    #[serde(default = "default_include_discarded")]
    pub include_discarded: bool,
    #[serde(default = "default_statuses")]
    pub statuses: String,
}

fn default_limit() -> usize {
    100 // Match Python default
}

fn default_include_discarded() -> bool {
    true // Match Python router default
}

fn default_statuses() -> String {
    "processing,completed".to_string() // Match Python default
}

/// GET /v1/conversations - Fetch user conversations
async fn get_conversations(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<GetConversationsQuery>,
) -> Result<Json<Vec<Conversation>>, (StatusCode, String)> {
    // Parse statuses from comma-separated string (match Python behavior)
    let statuses: Vec<String> = if query.statuses.is_empty() {
        vec![]
    } else {
        query.statuses.split(',').map(|s| s.trim().to_string()).collect()
    };

    tracing::info!(
        "Getting conversations for user {} with limit={}, offset={}, include_discarded={}, statuses={:?}",
        user.uid,
        query.limit,
        query.offset,
        query.include_discarded,
        statuses
    );

    match state
        .firestore
        .get_conversations(&user.uid, query.limit, query.offset, query.include_discarded, &statuses)
        .await
    {
        Ok(conversations) => Ok(Json(conversations)),
        Err(e) => {
            tracing::error!("Failed to get conversations: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get conversations: {}", e)))
        }
    }
}

/// POST /v1/conversations/from-segments - Create conversation from transcript
/// Copied from Python create_conversation_from_segments
async fn create_conversation_from_segments(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<CreateConversationRequest>,
) -> Result<Json<CreateConversationResponse>, (StatusCode, String)> {
    tracing::info!(
        "Creating conversation for user {} from {} segments",
        user.uid,
        request.transcript_segments.len()
    );

    // Get LLM client
    let llm_client = if let Some(api_key) = &state.config.gemini_api_key {
        LlmClient::gemini(api_key.clone())
    } else if let Some(api_key) = &state.config.openai_api_key {
        LlmClient::openai(api_key.clone())
    } else {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "No LLM API key configured".to_string(),
        ));
    };

    // Get existing data for deduplication
    let existing_memories = state
        .firestore
        .get_memories(&user.uid, 500)
        .await
        .unwrap_or_default();

    let existing_action_items = vec![]; // TODO: Fetch from Firestore

    // Format timestamps
    let started_at = request.started_at.to_rfc3339();
    let user_name = "User"; // TODO: Get from user profile

    // Process conversation with LLM
    let processed = llm_client
        .process_conversation(
            &request.transcript_segments,
            &started_at,
            &request.timezone,
            &request.language,
            user_name,
            &existing_action_items,
            &existing_memories,
        )
        .await
        .map_err(|e| {
            tracing::error!("Failed to process conversation: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        })?;

    // Generate conversation ID
    let conversation_id = uuid::Uuid::new_v4().to_string();

    if processed.discarded {
        return Ok(Json(CreateConversationResponse {
            id: conversation_id,
            status: "completed".to_string(),
            discarded: true,
        }));
    }

    // Create conversation object
    let conversation = Conversation {
        id: conversation_id.clone(),
        created_at: Utc::now(),
        started_at: request.started_at,
        finished_at: request.finished_at,
        source: ConversationSource::Desktop,
        language: request.language.clone(),
        status: ConversationStatus::Completed,
        discarded: false,
        structured: processed.structured,
        transcript_segments: request.transcript_segments.clone(),
    };

    // Save conversation
    if let Err(e) = state.firestore.save_conversation(&user.uid, &conversation).await {
        tracing::error!("Failed to save conversation: {}", e);
        return Err((StatusCode::INTERNAL_SERVER_ERROR, e.to_string()));
    }

    // Save action items
    if !processed.action_items.is_empty() {
        if let Err(e) = state
            .firestore
            .save_action_items(&user.uid, &conversation_id, &processed.action_items)
            .await
        {
            tracing::error!("Failed to save action items: {}", e);
        }
    }

    // Save memories
    if !processed.memories.is_empty() {
        if let Err(e) = state
            .firestore
            .save_memories(&user.uid, &conversation_id, &processed.memories)
            .await
        {
            tracing::error!("Failed to save memories: {}", e);
        }
    }

    Ok(Json(CreateConversationResponse {
        id: conversation_id,
        status: "completed".to_string(),
        discarded: false,
    }))
}

pub fn conversations_routes() -> Router<AppState> {
    Router::new()
        .route("/v1/conversations", get(get_conversations))
        .route(
            "/v1/conversations/from-segments",
            post(create_conversation_from_segments),
        )
}
