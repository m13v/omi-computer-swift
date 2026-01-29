// Messages routes for chat functionality
// Matching OMI Python backend /v2/messages endpoints

use axum::{
    extract::{Query, State},
    http::StatusCode,
    routing::{delete, get, post},
    Json, Router,
};
use serde::Serialize;

use crate::auth::AuthUser;
use crate::llm::{ChatMessageInput, LlmClient};
use crate::models::{GetMessagesQuery, Message, MessageAppQuery, MessageSender, SendMessageRequest};
use crate::AppState;

/// Build the messages router
pub fn messages_routes() -> Router<AppState> {
    Router::new()
        .route("/v2/messages", get(get_messages))
        .route("/v2/messages", post(send_message))
        .route("/v2/messages", delete(clear_messages))
}

/// GET /v2/messages - Get chat messages
async fn get_messages(
    user: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<GetMessagesQuery>,
) -> Result<Json<Vec<Message>>, (StatusCode, String)> {
    let uid = &user.uid;
    let app_id = query.app_id.as_deref();

    tracing::info!("Getting messages for user {} (app_id: {:?})", uid, app_id);

    let messages = state
        .firestore
        .get_messages(uid, query.limit, app_id)
        .await
        .map_err(|e| {
            tracing::error!("Failed to get messages: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        })?;

    Ok(Json(messages))
}

/// Response for send message endpoint
#[derive(Debug, Serialize)]
struct SendMessageResponse {
    #[serde(flatten)]
    message: Message,
}

/// POST /v2/messages - Send a message and get AI response
async fn send_message(
    user: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<MessageAppQuery>,
    Json(request): Json<SendMessageRequest>,
) -> Result<Json<SendMessageResponse>, (StatusCode, String)> {
    let uid = &user.uid;
    let app_id = query.app_id.as_deref();

    tracing::info!(
        "Sending message for user {} (app_id: {:?}): {}",
        uid,
        app_id,
        &request.text[..request.text.len().min(50)]
    );

    // Get or create chat session
    let session = state
        .firestore
        .get_or_create_chat_session(uid, app_id)
        .await
        .map_err(|e| {
            tracing::error!("Failed to get/create chat session: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        })?;

    // Create and save human message
    let human_message = Message::human(
        request.text.clone(),
        app_id.map(|s| s.to_string()),
        Some(session.id.clone()),
    );

    state
        .firestore
        .add_message(uid, &human_message)
        .await
        .map_err(|e| {
            tracing::error!("Failed to add human message: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        })?;

    // Get conversation history for context
    let messages = state
        .firestore
        .get_messages(uid, 20, app_id)
        .await
        .unwrap_or_default();

    // Get user's memories for context
    let memories = state
        .firestore
        .get_memories(uid, 50)
        .await
        .unwrap_or_default();

    // Get app details if app_id is provided
    let (app_name, app_prompt) = if let Some(aid) = app_id {
        match state.firestore.get_app(uid, aid).await {
            Ok(Some(app)) => (
                Some(app.name.clone()),
                app.chat_prompt.or(app.persona_prompt),
            ),
            _ => (None, None),
        }
    } else {
        (None, None)
    };

    // Build conversation history for LLM
    let chat_history: Vec<ChatMessageInput> = messages
        .iter()
        .map(|m| ChatMessageInput {
            role: match m.sender {
                MessageSender::Human => "user".to_string(),
                MessageSender::Ai => "assistant".to_string(),
            },
            content: m.text.clone(),
        })
        .chain(std::iter::once(ChatMessageInput {
            role: "user".to_string(),
            content: request.text.clone(),
        }))
        .collect();

    // Get user name (use "User" as default - AuthUser doesn't have email)
    let user_name = "User";

    // Generate AI response
    let openai_key = state.config.openai_api_key.clone().unwrap_or_default();
    let llm = LlmClient::openai(openai_key);

    let ai_response = llm
        .chat_response(
            &chat_history,
            user_name,
            &memories,
            app_name.as_deref(),
            app_prompt.as_deref(),
        )
        .await
        .map_err(|e| {
            tracing::error!("Failed to generate AI response: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        })?;

    // Create and save AI message
    let ai_message = Message::ai(
        ai_response,
        app_id.map(|s| s.to_string()),
        Some(session.id.clone()),
        vec![], // TODO: Could include memory IDs that were used
    );

    state
        .firestore
        .add_message(uid, &ai_message)
        .await
        .map_err(|e| {
            tracing::error!("Failed to add AI message: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        })?;

    Ok(Json(SendMessageResponse { message: ai_message }))
}

/// Response for clear messages endpoint
#[derive(Debug, Serialize)]
struct ClearMessagesResponse {
    deleted_count: usize,
    initial_message: Option<Message>,
}

/// DELETE /v2/messages - Clear chat messages and return initial greeting
async fn clear_messages(
    user: AuthUser,
    State(state): State<AppState>,
    Query(query): Query<MessageAppQuery>,
) -> Result<Json<ClearMessagesResponse>, (StatusCode, String)> {
    let uid = &user.uid;
    let app_id = query.app_id.as_deref();

    tracing::info!("Clearing messages for user {} (app_id: {:?})", uid, app_id);

    // Delete all messages
    let deleted_count = state
        .firestore
        .delete_messages(uid, app_id)
        .await
        .map_err(|e| {
            tracing::error!("Failed to delete messages: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, e.to_string())
        })?;

    // Generate and save initial greeting
    let initial_message = generate_initial_message(&state, uid, app_id).await.ok();

    if let Some(ref msg) = initial_message {
        let _ = state.firestore.add_message(uid, msg).await;
    }

    Ok(Json(ClearMessagesResponse {
        deleted_count,
        initial_message,
    }))
}

/// Generate an initial greeting message
async fn generate_initial_message(
    state: &AppState,
    uid: &str,
    app_id: Option<&str>,
) -> Result<Message, Box<dyn std::error::Error + Send + Sync>> {
    // Get user's memories for context
    let memories = state.firestore.get_memories(uid, 20).await.unwrap_or_default();

    // Get app details if app_id is provided
    let (app_name, app_prompt) = if let Some(aid) = app_id {
        match state.firestore.get_app(uid, aid).await {
            Ok(Some(app)) => (
                Some(app.name.clone()),
                app.chat_prompt.or(app.persona_prompt),
            ),
            _ => (None, None),
        }
    } else {
        (None, None)
    };

    // Create a new session
    let session = state
        .firestore
        .get_or_create_chat_session(uid, app_id)
        .await?;

    // Generate greeting
    let openai_key = state.config.openai_api_key.clone().unwrap_or_default();
    let llm = LlmClient::openai(openai_key);

    let greeting = llm
        .initial_chat_message("User", &memories, app_name.as_deref(), app_prompt.as_deref())
        .await?;

    let message = Message::ai(
        greeting,
        app_id.map(|s| s.to_string()),
        Some(session.id),
        vec![],
    );

    Ok(message)
}
