// Memories routes - Port from Python backend
// Endpoints: GET, POST, DELETE, PATCH /v3/memories

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{delete, get, patch, post},
    Json, Router,
};

use crate::auth::AuthUser;
use crate::models::{
    CreateMemoryRequest, CreateMemoryResponse, EditMemoryRequest, GetMemoriesQuery, MemoryDB,
    MemoryStatusResponse, ReviewMemoryRequest, UpdateMemoryReadRequest, UpdateVisibilityRequest,
};
use crate::AppState;

/// GET /v3/memories - Fetch user memories with optional filtering
/// Copied from Python get_memories endpoint
async fn get_memories(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<GetMemoriesQuery>,
) -> Json<Vec<MemoryDB>> {
    tracing::info!(
        "Getting memories for user {} with limit={}, offset={}, category={:?}, include_dismissed={}",
        user.uid,
        query.limit,
        query.offset,
        query.category,
        query.include_dismissed
    );

    match state
        .firestore
        .get_memories_filtered(
            &user.uid,
            query.limit,
            query.offset,
            query.category.as_deref(),
            query.include_dismissed,
        )
        .await
    {
        Ok(memories) => Json(memories),
        Err(e) => {
            tracing::error!("Failed to get memories: {}", e);
            Json(vec![])
        }
    }
}

/// POST /v3/memories - Create a new memory (manual or extracted)
async fn create_memory(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<CreateMemoryRequest>,
) -> Result<Json<CreateMemoryResponse>, StatusCode> {
    tracing::info!(
        "Creating memory for user {} with category={:?}, source_app={:?}",
        user.uid,
        request.category,
        request.source_app
    );

    match state
        .firestore
        .create_memory(
            &user.uid,
            &request.content,
            &request.visibility,
            request.category,
            request.confidence,
            request.source_app.as_deref(),
            request.context_summary.as_deref(),
        )
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

/// PATCH /v3/memories/:id/read - Update memory read/dismissed status
async fn update_memory_read(
    State(state): State<AppState>,
    user: AuthUser,
    Path(memory_id): Path<String>,
    Json(request): Json<UpdateMemoryReadRequest>,
) -> Result<Json<MemoryDB>, StatusCode> {
    tracing::info!("Updating read status for memory {} for user {}", memory_id, user.uid);

    match state
        .firestore
        .update_memory_read_status(&user.uid, &memory_id, request.is_read, request.is_dismissed)
        .await
    {
        Ok(memory) => Ok(Json(memory)),
        Err(e) => {
            tracing::error!("Failed to update memory read status: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// POST /v3/memories/mark-all-read - Mark all memories as read
async fn mark_all_read(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<MemoryStatusResponse>, StatusCode> {
    tracing::info!("Marking all memories as read for user {}", user.uid);

    match state.firestore.mark_all_memories_read(&user.uid).await {
        Ok(count) => {
            tracing::info!("Marked {} memories as read for user {}", count, user.uid);
            Ok(Json(MemoryStatusResponse {
                status: format!("marked {} as read", count),
            }))
        }
        Err(e) => {
            tracing::error!("Failed to mark all memories as read: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

pub fn memories_routes() -> Router<AppState> {
    Router::new()
        .route("/v3/memories", get(get_memories).post(create_memory))
        .route("/v3/memories/mark-all-read", post(mark_all_read))
        .route("/v3/memories/:id", delete(delete_memory).patch(edit_memory))
        .route("/v3/memories/:id/visibility", patch(update_visibility))
        .route("/v3/memories/:id/review", post(review_memory))
        .route("/v3/memories/:id/read", patch(update_memory_read))
}
