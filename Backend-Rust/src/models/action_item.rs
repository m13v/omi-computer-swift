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
