// Email routes - Inbound email webhook and management
// Endpoints:
//   POST /v1/webhooks/resend/inbound - Resend webhook (public)
//   GET /v1/emails - List emails (authenticated)
//   GET /v1/emails/{id} - Get email (authenticated)
//   POST /v1/emails/{id}/read - Mark read/unread (authenticated)
//   DELETE /v1/emails/{id} - Delete email (authenticated)

use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    routing::{get, post},
    Json, Router,
};

use crate::auth::AuthUser;
use crate::models::{
    EmailListResponse, EmailResponse, EmailStatusResponse, GetEmailsQuery, InboundEmailDB,
    MarkReadRequest, ResendWebhookPayload, WebhookResponse,
};
use crate::AppState;

/// POST /v1/webhooks/resend/inbound - Receive inbound email from Resend
/// This endpoint is public (no auth required) - Resend sends webhooks here
async fn resend_inbound_webhook(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(payload): Json<ResendWebhookPayload>,
) -> Result<Json<WebhookResponse>, StatusCode> {
    // Log webhook receipt with Svix headers for debugging
    let svix_id = headers
        .get("svix-id")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("none");

    tracing::info!(
        "Received Resend webhook: type={}, svix-id={}",
        payload.event_type,
        svix_id
    );

    // Only process email.received events
    if payload.event_type != "email.received" {
        return Ok(Json(WebhookResponse {
            status: "ignored".to_string(),
            email_id: None,
            event_type: Some(payload.event_type),
        }));
    }

    // Extract email ID (try email_id first, then id)
    let email_id = payload
        .data
        .email_id
        .or(payload.data.id)
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());

    // Convert attachments
    let attachments: Vec<crate::models::EmailAttachment> = payload
        .data
        .attachments
        .iter()
        .map(|att| crate::models::EmailAttachment {
            filename: if att.filename.is_empty() {
                "attachment".to_string()
            } else {
                att.filename.clone()
            },
            content_type: if att.content_type.is_empty() {
                "application/octet-stream".to_string()
            } else {
                att.content_type.clone()
            },
            size: att.content.as_ref().map(|c| c.len() as i64).unwrap_or(0),
        })
        .collect();

    // Create email record
    let email = InboundEmailDB {
        id: email_id.clone(),
        from_email: payload.data.from,
        to: payload.data.to,
        subject: if payload.data.subject.is_empty() {
            "(no subject)".to_string()
        } else {
            payload.data.subject
        },
        text: payload.data.text,
        html: payload.data.html,
        attachments,
        received_at: chrono::Utc::now(),
        read: false,
    };

    // Store in Firestore
    match state.firestore.create_email(&email).await {
        Ok(_) => {
            tracing::info!("Stored inbound email: {} from {}", email.id, email.from_email);
            Ok(Json(WebhookResponse {
                status: "ok".to_string(),
                email_id: Some(email.id),
                event_type: None,
            }))
        }
        Err(e) => {
            tracing::error!("Failed to store email: {}", e);
            Err(StatusCode::INTERNAL_SERVER_ERROR)
        }
    }
}

/// GET /v1/emails - List all inbound emails
async fn list_emails(
    State(state): State<AppState>,
    _user: AuthUser,
    Query(query): Query<GetEmailsQuery>,
) -> Result<Json<EmailListResponse>, StatusCode> {
    tracing::info!("Listing emails with limit={}, offset={}", query.limit, query.offset);

    let emails = state
        .firestore
        .list_emails(query.limit, query.offset)
        .await
        .map_err(|e| {
            tracing::error!("Failed to list emails: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    let total = state.firestore.get_email_count().await.unwrap_or(0);
    let unread = state.firestore.get_unread_email_count().await.unwrap_or(0);

    Ok(Json(EmailListResponse {
        emails: emails.into_iter().map(EmailResponse::from).collect(),
        total,
        unread,
    }))
}

/// GET /v1/emails/{id} - Get a specific email
async fn get_email(
    State(state): State<AppState>,
    _user: AuthUser,
    Path(email_id): Path<String>,
) -> Result<Json<EmailResponse>, StatusCode> {
    tracing::info!("Getting email: {}", email_id);

    let email = state
        .firestore
        .get_email(&email_id)
        .await
        .map_err(|e| {
            tracing::error!("Failed to get email: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?
        .ok_or(StatusCode::NOT_FOUND)?;

    // Mark as read when viewed
    let _ = state.firestore.mark_email_read(&email_id, true).await;

    Ok(Json(EmailResponse::from(email)))
}

/// POST /v1/emails/{id}/read - Mark email as read or unread
async fn mark_email_read(
    State(state): State<AppState>,
    _user: AuthUser,
    Path(email_id): Path<String>,
    Json(request): Json<MarkReadRequest>,
) -> Result<Json<EmailStatusResponse>, StatusCode> {
    tracing::info!("Marking email {} as read={}", email_id, request.read);

    state
        .firestore
        .mark_email_read(&email_id, request.read)
        .await
        .map_err(|e| {
            tracing::error!("Failed to mark email read: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    Ok(Json(EmailStatusResponse {
        status: "ok".to_string(),
        read: Some(request.read),
        deleted: None,
    }))
}

/// DELETE /v1/emails/{id} - Delete an email
async fn delete_email(
    State(state): State<AppState>,
    _user: AuthUser,
    Path(email_id): Path<String>,
) -> Result<Json<EmailStatusResponse>, StatusCode> {
    tracing::info!("Deleting email: {}", email_id);

    state
        .firestore
        .delete_email(&email_id)
        .await
        .map_err(|e| {
            tracing::error!("Failed to delete email: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        })?;

    Ok(Json(EmailStatusResponse {
        status: "ok".to_string(),
        read: None,
        deleted: Some(email_id),
    }))
}

pub fn emails_routes() -> Router<AppState> {
    Router::new()
        // Public webhook endpoint (no auth)
        .route("/v1/webhooks/resend/inbound", post(resend_inbound_webhook))
        // Authenticated endpoints
        .route("/v1/emails", get(list_emails))
        .route("/v1/emails/:id", get(get_email).delete(delete_email))
        .route("/v1/emails/:id/read", post(mark_email_read))
}
