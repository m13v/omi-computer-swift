// Action Items routes
// Endpoints: GET /v1/action-items, PATCH/DELETE /v1/action-items/{id}

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde::Deserialize;

use crate::auth::AuthUser;
use crate::models::{ActionItemDB, ActionItemsListResponse, ActionItemStatusResponse, BatchCreateActionItemsRequest, CreateActionItemRequest, UpdateActionItemRequest};
use crate::AppState;

#[derive(Deserialize)]
pub struct GetActionItemsQuery {
    #[serde(default = "default_limit")]
    pub limit: usize,
    #[serde(default)]
    pub offset: usize,
    /// Optional filter: true = completed only, false = pending only, None = all
    pub completed: Option<bool>,
    /// Optional filter by conversation ID
    pub conversation_id: Option<String>,
    /// ISO8601 date - filter created_at >= start_date
    pub start_date: Option<String>,
    /// ISO8601 date - filter created_at <= end_date
    pub end_date: Option<String>,
    /// ISO8601 date - filter due_at >= due_start_date
    pub due_start_date: Option<String>,
    /// ISO8601 date - filter due_at <= due_end_date
    pub due_end_date: Option<String>,
    /// Sort field: "due_at", "created_at", "priority" (default: created_at DESC)
    pub sort_by: Option<String>,
}

fn default_limit() -> usize {
    100
}

/// POST /v1/action-items - Create a new action item
async fn create_action_item(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<CreateActionItemRequest>,
) -> Result<Json<ActionItemDB>, StatusCode> {
    tracing::info!(
        "Creating action item for user {} with source={:?}, priority={:?}",
        user.uid,
        request.source,
        request.priority
    );

    match state
        .firestore
        .create_action_item(
            &user.uid,
            &request.description,
            request.due_at,
            request.source.as_deref(),
            request.priority.as_deref(),
            request.metadata.as_deref(),
        )
        .await
    {
        Ok(item) => Ok(Json(item)),
        Err(e) => {
            tracing::error!("Failed to create action item: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// GET /v1/action-items - Fetch user action items
async fn get_action_items(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<GetActionItemsQuery>,
) -> Json<ActionItemsListResponse> {
    tracing::info!(
        "Getting action items for user {} with limit={}, offset={}, completed={:?}, conversation_id={:?}, sort_by={:?}",
        user.uid,
        query.limit,
        query.offset,
        query.completed,
        query.conversation_id,
        query.sort_by
    );

    // Fetch limit + 1 to determine if there are more items
    let fetch_limit = query.limit + 1;

    match state
        .firestore
        .get_action_items(
            &user.uid,
            fetch_limit,
            query.offset,
            query.completed,
            query.conversation_id.as_deref(),
            query.start_date.as_deref(),
            query.end_date.as_deref(),
            query.due_start_date.as_deref(),
            query.due_end_date.as_deref(),
            query.sort_by.as_deref(),
        )
        .await
    {
        Ok(mut items) => {
            let has_more = items.len() > query.limit;
            if has_more {
                items.truncate(query.limit);
            }
            Json(ActionItemsListResponse { items, has_more })
        }
        Err(e) => {
            tracing::error!("Failed to get action items: {}", e);
            Json(ActionItemsListResponse {
                items: vec![],
                has_more: false,
            })
        }
    }
}

/// GET /v1/action-items/{id} - Get a single action item
async fn get_action_item_by_id(
    State(state): State<AppState>,
    user: AuthUser,
    Path(item_id): Path<String>,
) -> Result<Json<ActionItemDB>, StatusCode> {
    tracing::info!("Getting action item {} for user {}", item_id, user.uid);

    match state.firestore.get_action_item_by_id(&user.uid, &item_id).await {
        Ok(Some(item)) => Ok(Json(item)),
        Ok(None) => Err(StatusCode::NOT_FOUND),
        Err(e) => {
            tracing::error!("Failed to get action item: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// PATCH /v1/action-items/{id} - Update an action item
async fn update_action_item(
    State(state): State<AppState>,
    user: AuthUser,
    Path(item_id): Path<String>,
    Json(request): Json<UpdateActionItemRequest>,
) -> Result<Json<ActionItemDB>, StatusCode> {
    tracing::info!("Updating action item {} for user {}", item_id, user.uid);

    match state
        .firestore
        .update_action_item(
            &user.uid,
            &item_id,
            request.completed,
            request.description.as_deref(),
            request.due_at,
        )
        .await
    {
        Ok(item) => Ok(Json(item)),
        Err(e) => {
            tracing::error!("Failed to update action item: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// POST /v1/action-items/batch - Create multiple action items at once
async fn batch_create_action_items(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<BatchCreateActionItemsRequest>,
) -> Result<Json<Vec<ActionItemDB>>, StatusCode> {
    tracing::info!(
        "Batch creating {} action items for user {}",
        request.items.len(),
        user.uid
    );

    let mut created_items = Vec::new();

    for item_request in request.items {
        match state
            .firestore
            .create_action_item(
                &user.uid,
                &item_request.description,
                item_request.due_at,
                item_request.source.as_deref(),
                item_request.priority.as_deref(),
                item_request.metadata.as_deref(),
            )
            .await
        {
            Ok(item) => created_items.push(item),
            Err(e) => {
                tracing::error!("Failed to create action item in batch: {}", e);
                // Continue with other items, don't fail the whole batch
            }
        }
    }

    Ok(Json(created_items))
}

/// DELETE /v1/action-items/{id} - Delete an action item
async fn delete_action_item(
    State(state): State<AppState>,
    user: AuthUser,
    Path(item_id): Path<String>,
) -> Result<Json<ActionItemStatusResponse>, StatusCode> {
    tracing::info!("Deleting action item {} for user {}", item_id, user.uid);

    match state.firestore.delete_action_item(&user.uid, &item_id).await {
        Ok(()) => Ok(Json(ActionItemStatusResponse {
            status: "ok".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to delete action item: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

pub fn action_items_routes() -> Router<AppState> {
    Router::new()
        .route("/v1/action-items", get(get_action_items).post(create_action_item))
        .route("/v1/action-items/batch", axum::routing::post(batch_create_action_items))
        .route(
            "/v1/action-items/:id",
            get(get_action_item_by_id).patch(update_action_item).delete(delete_action_item),
        )
}
