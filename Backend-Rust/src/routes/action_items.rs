// Action Items routes
// Endpoints: GET /v1/action-items, PATCH/DELETE /v1/action-items/{id}

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, patch},
    Json, Router,
};
use serde::Deserialize;

use crate::auth::AuthUser;
use crate::models::{ActionItemDB, ActionItemStatusResponse, UpdateActionItemRequest};
use crate::AppState;

#[derive(Deserialize)]
pub struct GetActionItemsQuery {
    #[serde(default = "default_limit")]
    pub limit: usize,
    #[serde(default)]
    pub offset: usize,
    /// Optional filter: true = completed only, false = pending only, None = all
    pub completed: Option<bool>,
}

fn default_limit() -> usize {
    100
}

/// GET /v1/action-items - Fetch user action items
async fn get_action_items(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<GetActionItemsQuery>,
) -> Json<Vec<ActionItemDB>> {
    tracing::info!(
        "Getting action items for user {} with limit={}, offset={}, completed={:?}",
        user.uid,
        query.limit,
        query.offset,
        query.completed
    );

    match state
        .firestore
        .get_action_items(&user.uid, query.limit, query.offset, query.completed)
        .await
    {
        Ok(items) => Json(items),
        Err(e) => {
            tracing::error!("Failed to get action items: {}", e);
            Json(vec![])
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
        .route("/v1/action-items", get(get_action_items))
        .route(
            "/v1/action-items/{id}",
            patch(update_action_item).delete(delete_action_item),
        )
}
