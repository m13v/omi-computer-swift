// Daily Score routes
// Endpoint: GET /v1/daily-score

use axum::{
    extract::{Query, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use chrono::{NaiveDate, Utc};

use crate::auth::AuthUser;
use crate::models::{DailyScore, DailyScoreQuery};
use crate::AppState;

/// GET /v1/daily-score - Calculate daily score from action items due today
async fn get_daily_score(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<DailyScoreQuery>,
) -> Result<Json<DailyScore>, StatusCode> {
    // Parse date or use today
    let date = match query.date {
        Some(date_str) => {
            NaiveDate::parse_from_str(&date_str, "%Y-%m-%d")
                .map_err(|_| {
                    tracing::error!("Invalid date format: {}", date_str);
                    StatusCode::BAD_REQUEST
                })?
        }
        None => Utc::now().date_naive(),
    };

    let date_str = date.format("%Y-%m-%d").to_string();
    tracing::info!("Getting daily score for user {} on {}", user.uid, date_str);

    // Calculate start and end of day in UTC
    let due_start = format!("{}T00:00:00Z", date_str);
    let due_end = format!("{}T23:59:59.999Z", date_str);

    match state
        .firestore
        .get_action_items_for_daily_score(&user.uid, &due_start, &due_end)
        .await
    {
        Ok((completed_tasks, total_tasks)) => {
            let score = if total_tasks > 0 {
                (completed_tasks as f64 / total_tasks as f64) * 100.0
            } else {
                100.0 // No tasks = perfect score
            };

            Ok(Json(DailyScore {
                score,
                completed_tasks,
                total_tasks,
                date: date_str,
            }))
        }
        Err(e) => {
            tracing::error!("Failed to calculate daily score: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// Build the daily score router
pub fn daily_score_routes() -> Router<AppState> {
    Router::new().route("/v1/daily-score", get(get_daily_score))
}
