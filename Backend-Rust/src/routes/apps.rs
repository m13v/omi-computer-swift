// Apps routes - OMI Apps/Plugins system
// Endpoints for app discovery, management, and usage

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};

use crate::auth::AuthUser;
use crate::models::{
    App, AppCapabilityDef, AppCategory, AppReview, AppSummary, ListAppsQuery, SearchAppsQuery,
    SubmitReviewRequest, ToggleAppRequest, ToggleAppResponse, get_app_capabilities,
    get_app_categories,
};
use crate::AppState;

// ============================================================================
// App Discovery Endpoints
// ============================================================================

/// GET /v1/apps - List all available apps
async fn list_apps(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<ListAppsQuery>,
) -> Result<Json<Vec<AppSummary>>, (StatusCode, String)> {
    tracing::info!(
        "Listing apps for user {} with capability={:?}, category={:?}, limit={}, offset={}",
        user.uid,
        query.capability,
        query.category,
        query.limit,
        query.offset
    );

    match state
        .firestore
        .get_apps(&user.uid, query.limit, query.offset, query.capability.as_deref(), query.category.as_deref())
        .await
    {
        Ok(apps) => Ok(Json(apps)),
        Err(e) => {
            tracing::error!("Failed to get apps: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get apps: {}", e)))
        }
    }
}

/// GET /v1/approved-apps - List public approved apps only
async fn list_approved_apps(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<ListAppsQuery>,
) -> Result<Json<Vec<AppSummary>>, (StatusCode, String)> {
    tracing::info!("Listing approved apps for user {}", user.uid);

    match state
        .firestore
        .get_approved_apps(&user.uid, query.limit, query.offset)
        .await
    {
        Ok(apps) => Ok(Json(apps)),
        Err(e) => {
            tracing::error!("Failed to get approved apps: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get approved apps: {}", e)))
        }
    }
}

/// GET /v1/apps/popular - List popular apps
async fn list_popular_apps(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<Vec<AppSummary>>, (StatusCode, String)> {
    tracing::info!("Listing popular apps for user {}", user.uid);

    match state.firestore.get_popular_apps(&user.uid, 20).await {
        Ok(apps) => Ok(Json(apps)),
        Err(e) => {
            tracing::error!("Failed to get popular apps: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get popular apps: {}", e)))
        }
    }
}

/// GET /v2/apps/search - Search apps with filters
async fn search_apps(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<SearchAppsQuery>,
) -> Result<Json<Vec<AppSummary>>, (StatusCode, String)> {
    tracing::info!(
        "Searching apps for user {} with query={:?}, category={:?}, capability={:?}",
        user.uid,
        query.query,
        query.category,
        query.capability
    );

    match state
        .firestore
        .search_apps(
            &user.uid,
            query.query.as_deref(),
            query.category.as_deref(),
            query.capability.as_deref(),
            query.rating,
            query.my_apps,
            query.installed_apps,
            query.limit,
            query.offset,
        )
        .await
    {
        Ok(apps) => Ok(Json(apps)),
        Err(e) => {
            tracing::error!("Failed to search apps: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to search apps: {}", e)))
        }
    }
}

// ============================================================================
// App Details Endpoints
// ============================================================================

/// GET /v1/apps/:app_id - Get app details
async fn get_app_details(
    State(state): State<AppState>,
    user: AuthUser,
    Path(app_id): Path<String>,
) -> Result<Json<App>, (StatusCode, String)> {
    tracing::info!("Getting app details for {} by user {}", app_id, user.uid);

    match state.firestore.get_app(&user.uid, &app_id).await {
        Ok(Some(app)) => Ok(Json(app)),
        Ok(None) => Err((StatusCode::NOT_FOUND, "App not found".to_string())),
        Err(e) => {
            tracing::error!("Failed to get app: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get app: {}", e)))
        }
    }
}

/// GET /v1/apps/:app_id/reviews - Get app reviews
async fn get_app_reviews(
    State(state): State<AppState>,
    _user: AuthUser,
    Path(app_id): Path<String>,
) -> Result<Json<Vec<AppReview>>, (StatusCode, String)> {
    tracing::info!("Getting reviews for app {}", app_id);

    match state.firestore.get_app_reviews(&app_id).await {
        Ok(reviews) => Ok(Json(reviews)),
        Err(e) => {
            tracing::error!("Failed to get reviews: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get reviews: {}", e)))
        }
    }
}

// ============================================================================
// App Management Endpoints
// ============================================================================

/// POST /v1/apps/enable - Enable an app for the user
async fn enable_app(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<ToggleAppRequest>,
) -> Result<Json<ToggleAppResponse>, (StatusCode, String)> {
    tracing::info!("Enabling app {} for user {}", request.app_id, user.uid);

    match state.firestore.enable_app(&user.uid, &request.app_id).await {
        Ok(_) => Ok(Json(ToggleAppResponse {
            success: true,
            message: "App enabled successfully".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to enable app: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to enable app: {}", e)))
        }
    }
}

/// POST /v1/apps/disable - Disable an app for the user
async fn disable_app(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<ToggleAppRequest>,
) -> Result<Json<ToggleAppResponse>, (StatusCode, String)> {
    tracing::info!("Disabling app {} for user {}", request.app_id, user.uid);

    match state.firestore.disable_app(&user.uid, &request.app_id).await {
        Ok(_) => Ok(Json(ToggleAppResponse {
            success: true,
            message: "App disabled successfully".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to disable app: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to disable app: {}", e)))
        }
    }
}

/// GET /v1/apps/enabled - Get user's enabled apps
async fn get_enabled_apps(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<Vec<AppSummary>>, (StatusCode, String)> {
    tracing::info!("Getting enabled apps for user {}", user.uid);

    match state.firestore.get_enabled_apps(&user.uid).await {
        Ok(apps) => Ok(Json(apps)),
        Err(e) => {
            tracing::error!("Failed to get enabled apps: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to get enabled apps: {}", e)))
        }
    }
}

// ============================================================================
// Review Endpoints
// ============================================================================

/// POST /v1/apps/review - Submit a review for an app
async fn submit_review(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<SubmitReviewRequest>,
) -> Result<Json<AppReview>, (StatusCode, String)> {
    tracing::info!(
        "User {} submitting review for app {} with score {}",
        user.uid,
        request.app_id,
        request.score
    );

    // Validate score
    if request.score < 1 || request.score > 5 {
        return Err((StatusCode::BAD_REQUEST, "Score must be between 1 and 5".to_string()));
    }

    match state
        .firestore
        .submit_app_review(&user.uid, &request.app_id, request.score, &request.review)
        .await
    {
        Ok(review) => Ok(Json(review)),
        Err(e) => {
            tracing::error!("Failed to submit review: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, format!("Failed to submit review: {}", e)))
        }
    }
}

// ============================================================================
// Metadata Endpoints
// ============================================================================

/// GET /v1/app-categories - Get all app categories
async fn list_categories(
    _user: AuthUser,
) -> Result<Json<Vec<AppCategory>>, (StatusCode, String)> {
    Ok(Json(get_app_categories()))
}

/// GET /v1/app-capabilities - Get all app capabilities
async fn list_capabilities(
    _user: AuthUser,
) -> Result<Json<Vec<AppCapabilityDef>>, (StatusCode, String)> {
    Ok(Json(get_app_capabilities()))
}

// ============================================================================
// Router
// ============================================================================

pub fn apps_routes() -> Router<AppState> {
    Router::new()
        // Discovery
        .route("/v1/apps", get(list_apps))
        .route("/v1/approved-apps", get(list_approved_apps))
        .route("/v1/apps/popular", get(list_popular_apps))
        .route("/v2/apps/search", get(search_apps))
        // Details
        .route("/v1/apps/:app_id", get(get_app_details))
        .route("/v1/apps/:app_id/reviews", get(get_app_reviews))
        // Management
        .route("/v1/apps/enable", post(enable_app))
        .route("/v1/apps/disable", post(disable_app))
        .route("/v1/apps/enabled", get(get_enabled_apps))
        // Reviews
        .route("/v1/apps/review", post(submit_review))
        // Metadata
        .route("/v1/app-categories", get(list_categories))
        .route("/v1/app-capabilities", get(list_capabilities))
}
