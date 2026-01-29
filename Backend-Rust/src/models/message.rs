// Message models for chat functionality
// Matching OMI Python backend (models/chat.py)

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Message sender type
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum MessageSender {
    Ai,
    Human,
}

impl Default for MessageSender {
    fn default() -> Self {
        MessageSender::Human
    }
}

/// Message type
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum MessageType {
    Text,
    DaySummary,
}

impl Default for MessageType {
    fn default() -> Self {
        MessageType::Text
    }
}

/// A chat message
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Message {
    pub id: String,
    pub text: String,
    pub created_at: DateTime<Utc>,
    pub sender: MessageSender,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_id: Option<String>,
    #[serde(rename = "type")]
    pub message_type: MessageType,
    #[serde(default)]
    pub memories_id: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chat_session_id: Option<String>,
}

impl Message {
    /// Create a new human message
    pub fn human(text: String, app_id: Option<String>, session_id: Option<String>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            text,
            created_at: Utc::now(),
            sender: MessageSender::Human,
            app_id,
            message_type: MessageType::Text,
            memories_id: vec![],
            chat_session_id: session_id,
        }
    }

    /// Create a new AI message
    pub fn ai(text: String, app_id: Option<String>, session_id: Option<String>, memories_id: Vec<String>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            text,
            created_at: Utc::now(),
            sender: MessageSender::Ai,
            app_id,
            message_type: MessageType::Text,
            memories_id,
            chat_session_id: session_id,
        }
    }
}

/// A chat session
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatSession {
    pub id: String,
    pub created_at: DateTime<Utc>,
    #[serde(default)]
    pub message_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub app_id: Option<String>,
}

impl ChatSession {
    /// Create a new chat session
    pub fn new(app_id: Option<String>) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            created_at: Utc::now(),
            message_ids: vec![],
            app_id,
        }
    }
}

/// Request to send a message
#[derive(Debug, Clone, Deserialize)]
pub struct SendMessageRequest {
    pub text: String,
    #[serde(default)]
    pub file_ids: Vec<String>,
}

/// Query parameters for getting messages
#[derive(Debug, Clone, Deserialize)]
pub struct GetMessagesQuery {
    #[serde(default)]
    pub app_id: Option<String>,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_limit() -> usize {
    50
}

/// Query parameters for sending/clearing messages
#[derive(Debug, Clone, Deserialize)]
pub struct MessageAppQuery {
    #[serde(default)]
    pub app_id: Option<String>,
}
