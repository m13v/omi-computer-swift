// Conversations routes - Port from Python backend
// Endpoints: GET /v1/conversations, POST /v1/conversations/from-segments, POST /v1/conversations/:id/reprocess

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{delete, get, patch, post},
    Json, Router,
};
use chrono::Utc;
use serde::{Deserialize, Serialize};

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
    /// Filter by starred status (true = only starred, false/null = all)
    pub starred: Option<bool>,
    /// Filter by folder ID
    pub folder_id: Option<String>,
    /// Filter by start date (ISO 8601 format)
    pub start_date: Option<String>,
    /// Filter by end date (ISO 8601 format)
    pub end_date: Option<String>,
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
        "Getting conversations for user {} with limit={}, offset={}, include_discarded={}, statuses={:?}, starred={:?}, folder_id={:?}, start_date={:?}, end_date={:?}",
        user.uid,
        query.limit,
        query.offset,
        query.include_discarded,
        statuses,
        query.starred,
        query.folder_id,
        query.start_date,
        query.end_date
    );

    match state
        .firestore
        .get_conversations(
            &user.uid,
            query.limit,
            query.offset,
            query.include_discarded,
            &statuses,
            query.starred,
            query.folder_id.as_deref(),
            query.start_date.as_deref(),
            query.end_date.as_deref(),
        )
        .await
    {
        Ok(conversations) => Ok(Json(conversations)),
        Err(e) => {
            tracing::error!("Failed to get conversations: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get conversations: {}", e)))
        }
    }
}

#[derive(Deserialize)]
pub struct GetConversationsCountQuery {
    #[serde(default = "default_include_discarded")]
    pub include_discarded: bool,
    #[serde(default = "default_statuses")]
    pub statuses: String,
}

#[derive(Serialize)]
pub struct ConversationsCountResponse {
    pub count: i64,
}

/// GET /v1/conversations/count - Get count of user conversations
async fn get_conversations_count(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<GetConversationsCountQuery>,
) -> Result<Json<ConversationsCountResponse>, (StatusCode, String)> {
    let statuses: Vec<String> = if query.statuses.is_empty() {
        vec![]
    } else {
        query.statuses.split(',').map(|s| s.trim().to_string()).collect()
    };

    tracing::info!(
        "Getting conversations count for user {} with include_discarded={}, statuses={:?}",
        user.uid,
        query.include_discarded,
        statuses
    );

    match state
        .firestore
        .get_conversations_count(&user.uid, query.include_discarded, &statuses)
        .await
    {
        Ok(count) => Ok(Json(ConversationsCountResponse { count })),
        Err(e) => {
            tracing::error!("Failed to get conversations count: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get conversations count: {}", e)))
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

    // Get LLM client (Gemini)
    let llm_client = if let Some(api_key) = &state.config.gemini_api_key {
        LlmClient::new(api_key.clone())
    } else {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "GEMINI_API_KEY not configured".to_string(),
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
        starred: false,
        structured: processed.structured,
        transcript_segments: request.transcript_segments.clone(),
        apps_results: vec![],
        folder_id: None,
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

    // Trigger external integrations (async, don't block response)
    let integrations = state.integrations.clone();
    let firestore = state.firestore.clone();
    let uid = user.uid.clone();
    let conv_for_trigger = conversation.clone();

    tokio::spawn(async move {
        // Get user's enabled apps with full details
        match firestore.get_enabled_apps_full(&uid).await {
            Ok(enabled_apps) => {
                let results = integrations
                    .trigger_conversation_created(&uid, &conv_for_trigger, &enabled_apps)
                    .await;

                if !results.is_empty() {
                    let successful = results.iter().filter(|r| r.success).count();
                    let failed = results.len() - successful;
                    tracing::info!(
                        "Integration triggers completed: {} successful, {} failed",
                        successful,
                        failed
                    );
                }
            }
            Err(e) => {
                tracing::error!("Failed to get enabled apps for integration triggers: {}", e);
            }
        }
    });

    Ok(Json(CreateConversationResponse {
        id: conversation_id,
        status: "completed".to_string(),
        discarded: false,
    }))
}

#[derive(Deserialize)]
pub struct ReprocessRequest {
    app_id: String,
}

#[derive(Serialize)]
pub struct ReprocessResponse {
    success: bool,
    message: String,
    content: Option<String>,
}

/// POST /v1/conversations/:id/reprocess - Reprocess conversation with a specific app
async fn reprocess_conversation(
    State(state): State<AppState>,
    user: AuthUser,
    Path(conversation_id): Path<String>,
    Json(request): Json<ReprocessRequest>,
) -> Result<Json<ReprocessResponse>, (StatusCode, String)> {
    tracing::info!(
        "Reprocessing conversation {} with app {} for user {}",
        conversation_id,
        request.app_id,
        user.uid
    );

    // Fetch the conversation
    let conversation = state
        .firestore
        .get_conversation(&user.uid, &conversation_id)
        .await
        .map_err(|e| {
            tracing::error!("Failed to get conversation: {}", e);
            (StatusCode::NOT_FOUND, format!("Conversation not found: {}", e))
        })?
        .ok_or_else(|| {
            (StatusCode::NOT_FOUND, "Conversation not found".to_string())
        })?;

    // Fetch the app
    let app = state
        .firestore
        .get_app(&user.uid, &request.app_id)
        .await
        .map_err(|e| {
            tracing::error!("Failed to get app: {}", e);
            (StatusCode::NOT_FOUND, format!("App not found: {}", e))
        })?
        .ok_or_else(|| {
            (StatusCode::NOT_FOUND, "App not found".to_string())
        })?;

    // Check if app has memories capability
    if !app.capabilities.contains(&"memories".to_string()) {
        return Err((
            StatusCode::BAD_REQUEST,
            "App does not have memories capability".to_string(),
        ));
    }

    // Get the app's memory prompt
    let memory_prompt = app.memory_prompt.unwrap_or_else(|| {
        "Analyze this conversation and provide insights.".to_string()
    });

    // Get LLM client (Gemini)
    let llm_client = if let Some(api_key) = &state.config.gemini_api_key {
        LlmClient::new(api_key.clone())
    } else {
        return Err((
            StatusCode::INTERNAL_SERVER_ERROR,
            "GEMINI_API_KEY not configured".to_string(),
        ));
    };

    // Build transcript text
    let transcript_text: String = conversation
        .transcript_segments
        .iter()
        .map(|s| {
            let speaker = if s.is_user { "User".to_string() } else { format!("Speaker {}", s.speaker_id) };
            format!("{}: {}", speaker, s.text)
        })
        .collect::<Vec<_>>()
        .join("\n");

    // Run the app's memory prompt against the conversation
    let result = llm_client
        .run_memory_prompt(&memory_prompt, &transcript_text, &conversation.structured)
        .await
        .map_err(|e| {
            tracing::error!("Failed to run memory prompt: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to process: {}", e))
        })?;

    // Save the app result to the conversation
    if let Err(e) = state
        .firestore
        .add_app_result(&user.uid, &conversation_id, &request.app_id, &result)
        .await
    {
        tracing::error!("Failed to save app result: {}", e);
        // Continue anyway, just log the error
    }

    Ok(Json(ReprocessResponse {
        success: true,
        message: format!("Conversation reprocessed with {}", app.name),
        content: Some(result),
    }))
}

// Search request/response models
#[derive(Deserialize)]
pub struct SearchConversationsRequest {
    pub query: String,
    #[serde(default = "default_page")]
    pub page: usize,
    #[serde(default = "default_per_page")]
    pub per_page: usize,
    #[serde(default)]
    pub include_discarded: bool,
}

fn default_page() -> usize {
    1
}

fn default_per_page() -> usize {
    10
}

#[derive(Serialize)]
pub struct SearchConversationsResponse {
    pub items: Vec<Conversation>,
    pub total_pages: usize,
    pub current_page: usize,
    pub per_page: usize,
}

/// POST /v1/conversations/search - Search conversations by title and overview
async fn search_conversations(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<SearchConversationsRequest>,
) -> Result<Json<SearchConversationsResponse>, (StatusCode, String)> {
    tracing::info!(
        "Searching conversations for user {} with query '{}', page={}, per_page={}",
        user.uid,
        request.query,
        request.page,
        request.per_page
    );

    // Fetch all conversations (we'll filter in memory since Firestore doesn't support full-text search)
    let all_conversations = match state
        .firestore
        .get_conversations(&user.uid, 500, 0, request.include_discarded, &["completed".to_string()])
        .await
    {
        Ok(convs) => convs,
        Err(e) => {
            tracing::error!("Failed to get conversations for search: {}", e);
            return Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to search: {}", e)));
        }
    };

    // Filter by query (case-insensitive search in title and overview)
    let query_lower = request.query.to_lowercase();
    let filtered: Vec<Conversation> = all_conversations
        .into_iter()
        .filter(|conv| {
            let title_match = conv.structured.title.to_lowercase().contains(&query_lower);
            let overview_match = conv.structured.overview.to_lowercase().contains(&query_lower);
            title_match || overview_match
        })
        .collect();

    // Paginate results
    let total_count = filtered.len();
    let total_pages = (total_count + request.per_page - 1) / request.per_page.max(1);
    let start_idx = (request.page.saturating_sub(1)) * request.per_page;
    let items: Vec<Conversation> = filtered
        .into_iter()
        .skip(start_idx)
        .take(request.per_page)
        .collect();

    tracing::info!("Search found {} total matches, returning {} items", total_count, items.len());

    Ok(Json(SearchConversationsResponse {
        items,
        total_pages,
        current_page: request.page,
        per_page: request.per_page,
    }))
}

#[derive(Deserialize)]
pub struct StarredParams {
    starred: bool,
}

#[derive(Serialize)]
pub struct StatusResponse {
    status: String,
}

/// PATCH /v1/conversations/:id/starred - Set conversation starred status
async fn set_conversation_starred(
    State(state): State<AppState>,
    user: AuthUser,
    Path(conversation_id): Path<String>,
    Query(params): Query<StarredParams>,
) -> Result<Json<StatusResponse>, StatusCode> {
    tracing::info!(
        "Setting conversation {} starred={} for user {}",
        conversation_id,
        params.starred,
        user.uid
    );

    match state
        .firestore
        .set_conversation_starred(&user.uid, &conversation_id, params.starred)
        .await
    {
        Ok(()) => Ok(Json(StatusResponse {
            status: "ok".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to set starred: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

#[derive(Deserialize)]
pub struct UpdateConversationRequest {
    title: Option<String>,
}

/// DELETE /v1/conversations/:id - Delete a conversation
async fn delete_conversation(
    State(state): State<AppState>,
    user: AuthUser,
    Path(conversation_id): Path<String>,
) -> Result<StatusCode, StatusCode> {
    tracing::info!(
        "Deleting conversation {} for user {}",
        conversation_id,
        user.uid
    );

    match state
        .firestore
        .delete_conversation(&user.uid, &conversation_id)
        .await
    {
        Ok(()) => Ok(StatusCode::NO_CONTENT),
        Err(e) => {
            tracing::error!("Failed to delete conversation: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// PATCH /v1/conversations/:id - Update a conversation (title, etc.)
async fn update_conversation(
    State(state): State<AppState>,
    user: AuthUser,
    Path(conversation_id): Path<String>,
    Json(request): Json<UpdateConversationRequest>,
) -> Result<Json<StatusResponse>, StatusCode> {
    tracing::info!(
        "Updating conversation {} for user {}",
        conversation_id,
        user.uid
    );

    // Update title if provided
    if let Some(title) = &request.title {
        match state
            .firestore
            .update_conversation_title(&user.uid, &conversation_id, title)
            .await
        {
            Ok(()) => {},
            Err(e) => {
                tracing::error!("Failed to update conversation title: {}", e);
                return Err(StatusCode::INTERNAL_SERVER_ERROR);
            }
        }
    }

    Ok(Json(StatusResponse {
        status: "ok".to_string(),
    }))
}

pub fn conversations_routes() -> Router<AppState> {
    Router::new()
        .route("/v1/conversations", get(get_conversations))
        .route("/v1/conversations/count", get(get_conversations_count))
        .route("/v1/conversations/search", post(search_conversations))
        .route(
            "/v1/conversations/from-segments",
            post(create_conversation_from_segments),
        )
        .route(
            "/v1/conversations/:id/reprocess",
            post(reprocess_conversation),
        )
        .route(
            "/v1/conversations/:id/starred",
            patch(set_conversation_starred),
        )
        .route(
            "/v1/conversations/:id",
            patch(update_conversation).delete(delete_conversation),
        )
}
