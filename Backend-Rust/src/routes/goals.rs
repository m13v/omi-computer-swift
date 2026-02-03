// Goals routes
// Endpoints: GET /v1/goals/all, POST /v1/goals, PATCH /v1/goals/:id, PATCH /v1/goals/:id/progress, DELETE /v1/goals/:id

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{delete, get, patch, post},
    Json, Router,
};

use crate::auth::AuthUser;
use crate::models::{
    CreateGoalRequest, GoalDB, GoalStatusResponse, GoalType, GoalsListResponse,
    UpdateGoalProgressQuery, UpdateGoalRequest,
};
use crate::AppState;

/// GET /v1/goals/all - Get all active goals (up to 3)
async fn get_all_goals(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<GoalsListResponse>, StatusCode> {
    tracing::info!("Getting all goals for user {}", user.uid);

    match state.firestore.get_user_goals(&user.uid, 3).await {
        Ok(goals) => Ok(Json(GoalsListResponse { goals })),
        Err(e) => {
            tracing::error!("Failed to get goals: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// POST /v1/goals - Create a new goal
async fn create_goal(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<CreateGoalRequest>,
) -> Result<Json<GoalDB>, StatusCode> {
    tracing::info!(
        "Creating goal '{}' for user {} with type={:?}",
        request.title,
        user.uid,
        request.goal_type
    );

    let target_value = request.target_value.unwrap_or_else(|| {
        match request.goal_type {
            GoalType::Boolean => 1.0,
            _ => 100.0,
        }
    });

    match state
        .firestore
        .create_goal(
            &user.uid,
            &request.title,
            request.goal_type,
            target_value,
            request.current_value.unwrap_or(0.0),
            request.min_value.unwrap_or(0.0),
            request.max_value.unwrap_or(100.0),
            request.unit.as_deref(),
        )
        .await
    {
        Ok(goal) => Ok(Json(goal)),
        Err(e) => {
            tracing::error!("Failed to create goal: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// PATCH /v1/goals/:id - Update a goal
async fn update_goal(
    State(state): State<AppState>,
    user: AuthUser,
    Path(goal_id): Path<String>,
    Json(request): Json<UpdateGoalRequest>,
) -> Result<Json<GoalDB>, StatusCode> {
    tracing::info!("Updating goal {} for user {}", goal_id, user.uid);

    match state
        .firestore
        .update_goal(
            &user.uid,
            &goal_id,
            request.title.as_deref(),
            request.target_value,
            request.current_value,
            request.min_value,
            request.max_value,
            request.unit.as_deref(),
            request.is_active,
        )
        .await
    {
        Ok(goal) => Ok(Json(goal)),
        Err(e) => {
            tracing::error!("Failed to update goal: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// PATCH /v1/goals/:id/progress - Update goal progress
async fn update_goal_progress(
    State(state): State<AppState>,
    user: AuthUser,
    Path(goal_id): Path<String>,
    Query(query): Query<UpdateGoalProgressQuery>,
) -> Result<Json<GoalDB>, StatusCode> {
    tracing::info!(
        "Updating progress for goal {} to {} for user {}",
        goal_id,
        query.current_value,
        user.uid
    );

    match state
        .firestore
        .update_goal_progress(&user.uid, &goal_id, query.current_value)
        .await
    {
        Ok(goal) => Ok(Json(goal)),
        Err(e) => {
            tracing::error!("Failed to update goal progress: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// DELETE /v1/goals/:id - Delete a goal
async fn delete_goal(
    State(state): State<AppState>,
    user: AuthUser,
    Path(goal_id): Path<String>,
) -> Result<Json<GoalStatusResponse>, StatusCode> {
    tracing::info!("Deleting goal {} for user {}", goal_id, user.uid);

    match state.firestore.delete_goal(&user.uid, &goal_id).await {
        Ok(()) => Ok(Json(GoalStatusResponse {
            status: "deleted".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to delete goal: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// Build the goals router
pub fn goals_routes() -> Router<AppState> {
    Router::new()
        .route("/v1/goals/all", get(get_all_goals))
        .route("/v1/goals", post(create_goal))
        .route("/v1/goals/{id}", patch(update_goal))
        .route("/v1/goals/{id}/progress", patch(update_goal_progress))
        .route("/v1/goals/{id}", delete(delete_goal))
}
