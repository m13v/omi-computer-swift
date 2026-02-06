// Action Item models - standalone action items stored in Firestore
// Path: users/{uid}/action_items/{item_id}

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Action item stored in Firestore subcollection
/// Different from conversation.ActionItem which is embedded in conversation structured data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionItemDB {
    /// Document ID
    pub id: String,
    /// The action item description
    pub description: String,
    /// Whether the action item has been completed
    #[serde(default)]
    pub completed: bool,
    /// When the action item was created
    pub created_at: DateTime<Utc>,
    /// When the action item was last updated
    pub updated_at: Option<DateTime<Utc>>,
    /// When the action item is due
    pub due_at: Option<DateTime<Utc>>,
    /// When the action item was completed
    pub completed_at: Option<DateTime<Utc>>,
    /// The conversation this action item was extracted from
    pub conversation_id: Option<String>,
    /// Source of the action item: "screenshot", "transcription:omi", "transcription:desktop", "manual"
    #[serde(default)]
    pub source: Option<String>,
    /// Priority: "high", "medium", "low"
    #[serde(default)]
    pub priority: Option<String>,
    /// JSON metadata: {"source_app": "Safari", "confidence": 0.85}
    #[serde(default)]
    pub metadata: Option<String>,
    /// Soft-delete: true if this task has been deleted
    #[serde(default)]
    pub deleted: Option<bool>,
    /// Who deleted: "user", "ai_dedup"
    #[serde(default)]
    pub deleted_by: Option<String>,
    /// When the task was soft-deleted
    #[serde(default)]
    pub deleted_at: Option<DateTime<Utc>>,
    /// AI reason for deletion (dedup explanation)
    #[serde(default)]
    pub deleted_reason: Option<String>,
    /// ID of the task that was kept instead of this one
    #[serde(default)]
    pub kept_task_id: Option<String>,
}

/// Request body for updating an action item
#[derive(Debug, Clone, Deserialize)]
pub struct UpdateActionItemRequest {
    /// New completed status
    pub completed: Option<bool>,
    /// New description
    pub description: Option<String>,
    /// New due date
    pub due_at: Option<DateTime<Utc>>,
}

/// Response for action item status operations
#[derive(Debug, Clone, Serialize)]
pub struct ActionItemStatusResponse {
    pub status: String,
}

/// Response wrapper for paginated action items list
#[derive(Debug, Clone, Serialize)]
pub struct ActionItemsListResponse {
    pub items: Vec<ActionItemDB>,
    pub has_more: bool,
}

/// Request body for batch creating action items
#[derive(Debug, Clone, Deserialize)]
pub struct BatchCreateActionItemsRequest {
    pub items: Vec<CreateActionItemRequest>,
}

/// Request body for creating a new action item
#[derive(Debug, Clone, Deserialize)]
pub struct CreateActionItemRequest {
    /// The action item description (required)
    pub description: String,
    /// When the action item is due (optional)
    pub due_at: Option<DateTime<Utc>>,
    /// Source of the action item: "screenshot", "transcription:omi", "transcription:desktop", "manual"
    pub source: Option<String>,
    /// Priority: "high", "medium", "low"
    pub priority: Option<String>,
    /// JSON metadata string: {"source_app": "Safari", "confidence": 0.85}
    pub metadata: Option<String>,
}
