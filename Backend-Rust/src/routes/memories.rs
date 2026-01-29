// Memories routes - Port from Python backend
// Endpoints: GET, POST, DELETE, PATCH /v3/memories

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{delete, get, patch, post},
    Json, Router,
};
use serde::Deserialize;

use crate::auth::AuthUser;
use crate::models::{
    CreateMemoryRequest, CreateMemoryResponse, EditMemoryRequest, MemoryDB, MemoryStatusResponse,
    ReviewMemoryRequest, UpdateVisibilityRequest,
};
use crate::AppState;

#[derive(Deserialize)]
pub struct GetMemoriesQuery {
    #[serde(default = "default_limit")]
    pub limit: usize,
    #[serde(default)]
    pub offset: usize,
}

fn default_limit() -> usize {
    100
}

/// GET /v3/memories - Fetch user memories
/// Copied from Python get_memories endpoint
async fn get_memories(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<GetMemoriesQuery>,
) -> Json<Vec<MemoryDB>> {
    tracing::info!(
        "Getting memories for user {} with limit={}, offset={}",
        user.uid,
        query.limit,
        query.offset
    );

    match state.firestore.get_memories(&user.uid, query.limit).await {
        Ok(memories) => Json(memories),
        Err(e) => {
            tracing::error!("Failed to get memories: {}", e);
            Json(vec![])
        }
    }
}

/// POST /v3/memories - Create a new manual memory
async fn create_memory(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<CreateMemoryRequest>,
) -> Result<Json<CreateMemoryResponse>, StatusCode> {
    tracing::info!("Creating manual memory for user {}", user.uid);

    match state
        .firestore
        .create_manual_memory(&user.uid, &request.content, &request.visibility)
        .await
    {
        Ok(id) => Ok(Json(CreateMemoryResponse {
            id,
            message: "Memory created successfully".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to create memory: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// DELETE /v3/memories/:id - Delete a memory
async fn delete_memory(
    State(state): State<AppState>,
    user: AuthUser,
    Path(memory_id): Path<String>,
) -> Result<Json<MemoryStatusResponse>, StatusCode> {
    tracing::info!("Deleting memory {} for user {}", memory_id, user.uid);

    match state.firestore.delete_memory(&user.uid, &memory_id).await {
        Ok(()) => Ok(Json(MemoryStatusResponse {
            status: "ok".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to delete memory: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// PATCH /v3/memories/:id - Edit memory content
async fn edit_memory(
    State(state): State<AppState>,
    user: AuthUser,
    Path(memory_id): Path<String>,
    Json(request): Json<EditMemoryRequest>,
) -> Result<Json<MemoryStatusResponse>, StatusCode> {
    tracing::info!("Editing memory {} for user {}", memory_id, user.uid);

    match state
        .firestore
        .update_memory_content(&user.uid, &memory_id, &request.value)
        .await
    {
        Ok(()) => Ok(Json(MemoryStatusResponse {
            status: "ok".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to edit memory: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// PATCH /v3/memories/:id/visibility - Update memory visibility
async fn update_visibility(
    State(state): State<AppState>,
    user: AuthUser,
    Path(memory_id): Path<String>,
    Json(request): Json<UpdateVisibilityRequest>,
) -> Result<Json<MemoryStatusResponse>, StatusCode> {
    tracing::info!(
        "Updating visibility for memory {} for user {}",
        memory_id,
        user.uid
    );

    match state
        .firestore
        .update_memory_visibility(&user.uid, &memory_id, &request.value)
        .await
    {
        Ok(()) => Ok(Json(MemoryStatusResponse {
            status: "ok".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to update memory visibility: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// POST /v3/memories/:id/review - Review/approve a memory
async fn review_memory(
    State(state): State<AppState>,
    user: AuthUser,
    Path(memory_id): Path<String>,
    Json(request): Json<ReviewMemoryRequest>,
) -> Result<Json<MemoryStatusResponse>, StatusCode> {
    tracing::info!(
        "Reviewing memory {} for user {} with value {}",
        memory_id,
        user.uid,
        request.value
    );

    match state
        .firestore
        .review_memory(&user.uid, &memory_id, request.value)
        .await
    {
        Ok(()) => Ok(Json(MemoryStatusResponse {
            status: "ok".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to review memory: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

pub fn memories_routes() -> Router<AppState> {
    Router::new()
        .route("/v3/memories", get(get_memories).post(create_memory))
        .route("/v3/memories/:id", delete(delete_memory).patch(edit_memory))
        .route("/v3/memories/:id/visibility", patch(update_visibility))
        .route("/v3/memories/:id/review", post(review_memory))
}
