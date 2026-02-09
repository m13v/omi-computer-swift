// User settings routes
// Endpoints: /v1/users/*

use axum::{
    extract::{Query, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde::Deserialize;

use crate::auth::AuthUser;
use crate::models::{
    DailySummarySettings, NotificationSettings, PrivateCloudSync, RecordingPermission,
    TranscriptionPreferences, UpdateDailySummaryRequest, UpdateLanguageRequest,
    UpdateNotificationSettingsRequest, UpdateTranscriptionPreferencesRequest, UpdateUserAIPersonaRequest,
    UserAIPersona, UserLanguage, UserProfile, UserSettingsStatusResponse,
};
use crate::AppState;

// ============================================================================
// Daily Summary Settings
// ============================================================================

/// GET /v1/users/daily-summary-settings
async fn get_daily_summary_settings(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<DailySummarySettings>, StatusCode> {
    tracing::info!("Getting daily summary settings for user {}", user.uid);

    match state.firestore.get_daily_summary_settings(&user.uid).await {
        Ok(settings) => Ok(Json(settings)),
        Err(e) => {
            tracing::error!("Failed to get daily summary settings: {}", e);
            // Return defaults on error
            Ok(Json(DailySummarySettings::default()))
        }
    }
}

/// PATCH /v1/users/daily-summary-settings
async fn update_daily_summary_settings(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<UpdateDailySummaryRequest>,
) -> Result<Json<DailySummarySettings>, StatusCode> {
    tracing::info!("Updating daily summary settings for user {}", user.uid);

    // Validate hour if provided
    if let Some(hour) = request.hour {
        if !(0..=23).contains(&hour) {
            return Err(StatusCode::BAD_REQUEST);
        }
    }

    match state
        .firestore
        .update_daily_summary_settings(&user.uid, request.enabled, request.hour)
        .await
    {
        Ok(settings) => Ok(Json(settings)),
        Err(e) => {
            tracing::error!("Failed to update daily summary settings: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

// ============================================================================
// Transcription Preferences
// ============================================================================

/// GET /v1/users/transcription-preferences
async fn get_transcription_preferences(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<TranscriptionPreferences>, StatusCode> {
    tracing::info!("Getting transcription preferences for user {}", user.uid);

    match state
        .firestore
        .get_transcription_preferences(&user.uid)
        .await
    {
        Ok(prefs) => Ok(Json(prefs)),
        Err(e) => {
            tracing::error!("Failed to get transcription preferences: {}", e);
            Ok(Json(TranscriptionPreferences::default()))
        }
    }
}

/// PATCH /v1/users/transcription-preferences
async fn update_transcription_preferences(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<UpdateTranscriptionPreferencesRequest>,
) -> Result<Json<TranscriptionPreferences>, StatusCode> {
    tracing::info!("Updating transcription preferences for user {}", user.uid);

    // Validate vocabulary length if provided
    if let Some(ref vocab) = request.vocabulary {
        if vocab.len() > 100 {
            tracing::warn!("Vocabulary list too long: {} items (max 100)", vocab.len());
            return Err(StatusCode::BAD_REQUEST);
        }
    }

    match state
        .firestore
        .update_transcription_preferences(&user.uid, request.single_language_mode, request.vocabulary)
        .await
    {
        Ok(prefs) => Ok(Json(prefs)),
        Err(e) => {
            tracing::error!("Failed to update transcription preferences: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

// ============================================================================
// Language
// ============================================================================

/// GET /v1/users/language
async fn get_language(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<UserLanguage>, StatusCode> {
    tracing::info!("Getting language for user {}", user.uid);

    match state.firestore.get_user_language(&user.uid).await {
        Ok(lang) => Ok(Json(UserLanguage { language: lang })),
        Err(e) => {
            tracing::error!("Failed to get language: {}", e);
            Ok(Json(UserLanguage {
                language: "en".to_string(),
            }))
        }
    }
}

/// PATCH /v1/users/language
async fn update_language(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<UpdateLanguageRequest>,
) -> Result<Json<UserLanguage>, StatusCode> {
    tracing::info!(
        "Updating language for user {} to {}",
        user.uid,
        request.language
    );

    match state
        .firestore
        .update_user_language(&user.uid, &request.language)
        .await
    {
        Ok(()) => Ok(Json(UserLanguage {
            language: request.language,
        })),
        Err(e) => {
            tracing::error!("Failed to update language: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

// ============================================================================
// Recording Permission
// ============================================================================

#[derive(Deserialize)]
pub struct RecordingPermissionQuery {
    pub value: bool,
}

/// GET /v1/users/store-recording-permission
async fn get_recording_permission(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<RecordingPermission>, StatusCode> {
    tracing::info!("Getting recording permission for user {}", user.uid);

    match state.firestore.get_recording_permission(&user.uid).await {
        Ok(enabled) => Ok(Json(RecordingPermission { enabled })),
        Err(e) => {
            tracing::error!("Failed to get recording permission: {}", e);
            Ok(Json(RecordingPermission { enabled: false }))
        }
    }
}

/// POST /v1/users/store-recording-permission?value=true|false
async fn set_recording_permission(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<RecordingPermissionQuery>,
) -> Result<Json<UserSettingsStatusResponse>, StatusCode> {
    tracing::info!(
        "Setting recording permission for user {} to {}",
        user.uid,
        query.value
    );

    match state
        .firestore
        .set_recording_permission(&user.uid, query.value)
        .await
    {
        Ok(()) => Ok(Json(UserSettingsStatusResponse {
            status: "ok".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to set recording permission: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

// ============================================================================
// Private Cloud Sync
// ============================================================================

#[derive(Deserialize)]
pub struct PrivateCloudSyncQuery {
    pub value: bool,
}

/// GET /v1/users/private-cloud-sync
async fn get_private_cloud_sync(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<PrivateCloudSync>, StatusCode> {
    tracing::info!("Getting private cloud sync for user {}", user.uid);

    match state.firestore.get_private_cloud_sync(&user.uid).await {
        Ok(enabled) => Ok(Json(PrivateCloudSync { enabled })),
        Err(e) => {
            tracing::error!("Failed to get private cloud sync: {}", e);
            Ok(Json(PrivateCloudSync { enabled: true })) // Default to enabled
        }
    }
}

/// POST /v1/users/private-cloud-sync?value=true|false
async fn set_private_cloud_sync(
    State(state): State<AppState>,
    user: AuthUser,
    Query(query): Query<PrivateCloudSyncQuery>,
) -> Result<Json<UserSettingsStatusResponse>, StatusCode> {
    tracing::info!(
        "Setting private cloud sync for user {} to {}",
        user.uid,
        query.value
    );

    match state
        .firestore
        .set_private_cloud_sync(&user.uid, query.value)
        .await
    {
        Ok(()) => Ok(Json(UserSettingsStatusResponse {
            status: "ok".to_string(),
        })),
        Err(e) => {
            tracing::error!("Failed to set private cloud sync: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

// ============================================================================
// Notification Settings
// ============================================================================

/// GET /v1/users/notification-settings
async fn get_notification_settings(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<NotificationSettings>, StatusCode> {
    tracing::info!("Getting notification settings for user {}", user.uid);

    match state.firestore.get_notification_settings(&user.uid).await {
        Ok(settings) => Ok(Json(settings)),
        Err(e) => {
            tracing::error!("Failed to get notification settings: {}", e);
            Ok(Json(NotificationSettings {
                enabled: true,
                frequency: 3,
            }))
        }
    }
}

/// PATCH /v1/users/notification-settings
async fn update_notification_settings(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<UpdateNotificationSettingsRequest>,
) -> Result<Json<NotificationSettings>, StatusCode> {
    tracing::info!("Updating notification settings for user {}", user.uid);

    // Validate frequency if provided
    if let Some(freq) = request.frequency {
        if !(0..=5).contains(&freq) {
            return Err(StatusCode::BAD_REQUEST);
        }
    }

    match state
        .firestore
        .update_notification_settings(&user.uid, request.enabled, request.frequency)
        .await
    {
        Ok(settings) => Ok(Json(settings)),
        Err(e) => {
            tracing::error!("Failed to update notification settings: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

// ============================================================================
// User Profile
// ============================================================================

/// GET /v1/users/profile
async fn get_profile(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<UserProfile>, StatusCode> {
    tracing::info!("Getting profile for user {}", user.uid);

    match state.firestore.get_user_profile(&user.uid).await {
        Ok(profile) => Ok(Json(profile)),
        Err(e) => {
            tracing::error!("Failed to get profile: {}", e);
            // Return minimal profile on error
            Ok(Json(UserProfile {
                uid: user.uid,
                email: None,
                name: None,
                time_zone: None,
                created_at: None,
            }))
        }
    }
}

// ============================================================================
// User Persona
// ============================================================================

/// GET /v1/users/persona
async fn get_persona(
    State(state): State<AppState>,
    user: AuthUser,
) -> Result<Json<Option<UserAIPersona>>, StatusCode> {
    tracing::info!("Getting AI persona for user {}", user.uid);

    match state.firestore.get_user_ai_persona(&user.uid).await {
        Ok(persona) => Ok(Json(persona)),
        Err(e) => {
            tracing::error!("Failed to get AI persona: {}", e);
            Ok(Json(None))
        }
    }
}

/// PATCH /v1/users/persona
async fn update_persona(
    State(state): State<AppState>,
    user: AuthUser,
    Json(request): Json<UpdateUserAIPersonaRequest>,
) -> Result<Json<UserAIPersona>, StatusCode> {
    tracing::info!("Updating AI persona for user {}", user.uid);

    if request.persona_text.len() > 2000 {
        tracing::warn!("Persona text too long: {} chars (max 2000)", request.persona_text.len());
        return Err(StatusCode::BAD_REQUEST);
    }

    match state
        .firestore
        .update_user_ai_persona(
            &user.uid,
            &request.persona_text,
            &request.generated_at,
            request.data_sources_used,
        )
        .await
    {
        Ok(persona) => Ok(Json(persona)),
        Err(e) => {
            tracing::error!("Failed to update AI persona: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

// ============================================================================
// Router
// ============================================================================

pub fn users_routes() -> Router<AppState> {
    Router::new()
        // Daily summary
        .route(
            "/v1/users/daily-summary-settings",
            get(get_daily_summary_settings).patch(update_daily_summary_settings),
        )
        // Transcription
        .route(
            "/v1/users/transcription-preferences",
            get(get_transcription_preferences).patch(update_transcription_preferences),
        )
        // Language
        .route(
            "/v1/users/language",
            get(get_language).patch(update_language),
        )
        // Recording permission
        .route(
            "/v1/users/store-recording-permission",
            get(get_recording_permission).post(set_recording_permission),
        )
        // Private cloud sync
        .route(
            "/v1/users/private-cloud-sync",
            get(get_private_cloud_sync).post(set_private_cloud_sync),
        )
        // Notification settings
        .route(
            "/v1/users/notification-settings",
            get(get_notification_settings).patch(update_notification_settings),
        )
        // Profile
        .route("/v1/users/profile", get(get_profile))
        // Persona
        .route(
            "/v1/users/persona",
            get(get_persona).patch(update_persona),
        )
}
