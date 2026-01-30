// Inbound email models - emails received via Resend webhook
// Path: emails/{email_id}

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Email attachment metadata
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmailAttachment {
    pub filename: String,
    pub content_type: String,
    pub size: i64,
}

/// Inbound email stored in Firestore
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InboundEmailDB {
    /// Document ID
    pub id: String,
    /// Sender email address
    #[serde(rename = "from")]
    pub from_email: String,
    /// Recipient email addresses
    pub to: Vec<String>,
    /// Email subject
    pub subject: String,
    /// Plain text body
    #[serde(default)]
    pub text: Option<String>,
    /// HTML body
    #[serde(default)]
    pub html: Option<String>,
    /// Attachment metadata
    #[serde(default)]
    pub attachments: Vec<EmailAttachment>,
    /// When the email was received
    pub received_at: DateTime<Utc>,
    /// Whether the email has been read
    #[serde(default)]
    pub read: bool,
}

/// Response for single email
#[derive(Debug, Clone, Serialize)]
pub struct EmailResponse {
    pub id: String,
    pub from_email: String,
    pub to: Vec<String>,
    pub subject: String,
    pub text: Option<String>,
    pub html: Option<String>,
    pub received_at: String,
    pub read: bool,
}

impl From<InboundEmailDB> for EmailResponse {
    fn from(email: InboundEmailDB) -> Self {
        Self {
            id: email.id,
            from_email: email.from_email,
            to: email.to,
            subject: email.subject,
            text: email.text,
            html: email.html,
            received_at: email.received_at.to_rfc3339(),
            read: email.read,
        }
    }
}

/// Response for email list
#[derive(Debug, Clone, Serialize)]
pub struct EmailListResponse {
    pub emails: Vec<EmailResponse>,
    pub total: i64,
    pub unread: i64,
}

/// Resend webhook payload for email.received event
#[derive(Debug, Clone, Deserialize)]
pub struct ResendWebhookPayload {
    #[serde(rename = "type")]
    pub event_type: String,
    pub created_at: String,
    pub data: ResendEmailData,
}

/// Email data from Resend webhook
#[derive(Debug, Clone, Deserialize)]
pub struct ResendEmailData {
    pub email_id: Option<String>,
    pub id: Option<String>,
    #[serde(default)]
    pub from: String,
    #[serde(default)]
    pub to: Vec<String>,
    #[serde(default)]
    pub subject: String,
    pub text: Option<String>,
    pub html: Option<String>,
    #[serde(default)]
    pub attachments: Vec<ResendAttachment>,
}

/// Attachment from Resend webhook
#[derive(Debug, Clone, Deserialize)]
pub struct ResendAttachment {
    #[serde(default)]
    pub filename: String,
    #[serde(default)]
    pub content_type: String,
    pub content: Option<String>,
}

/// Response for webhook acknowledgment
#[derive(Debug, Clone, Serialize)]
pub struct WebhookResponse {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email_id: Option<String>,
    #[serde(rename = "type", skip_serializing_if = "Option::is_none")]
    pub event_type: Option<String>,
}

/// Response for status operations
#[derive(Debug, Clone, Serialize)]
pub struct EmailStatusResponse {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub read: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deleted: Option<String>,
}

/// Query parameters for listing emails
#[derive(Debug, Clone, Deserialize)]
pub struct GetEmailsQuery {
    #[serde(default = "default_limit")]
    pub limit: usize,
    #[serde(default)]
    pub offset: usize,
}

fn default_limit() -> usize {
    50
}

/// Request body for marking email read/unread
#[derive(Debug, Clone, Deserialize)]
pub struct MarkReadRequest {
    #[serde(default = "default_read")]
    pub read: bool,
}

fn default_read() -> bool {
    true
}
