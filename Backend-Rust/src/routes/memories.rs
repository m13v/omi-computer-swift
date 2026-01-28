// Memories routes - Port from Python backend
// Endpoint: GET /v3/memories

use axum::{
    extract::{Query, State},
    routing::get,
    Json, Router,
};
use serde::Deserialize;

use crate::auth::AuthUser;
use crate::models::MemoryDB;
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

pub fn memories_routes() -> Router<AppState> {
    Router::new().route("/v3/memories", get(get_memories))
}
