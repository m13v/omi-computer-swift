// Firestore service - Port from Python backend (database.py)
// Uses Firestore REST API for simplicity and compatibility

use chrono::{DateTime, Utc};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;

use crate::models::{
    ActionItem, Category, Conversation, ConversationSource, ConversationStatus, Event, Memory,
    MemoryCategory, MemoryDB, Structured, TranscriptSegment,
};

/// Firestore collection paths
/// Copied from Python database.py
pub const USERS_COLLECTION: &str = "users";
pub const CONVERSATIONS_SUBCOLLECTION: &str = "conversations";
pub const ACTION_ITEMS_SUBCOLLECTION: &str = "action_items";
pub const MEMORIES_SUBCOLLECTION: &str = "memories";

/// Generate a document ID from a seed string using SHA256 hash
/// Copied from Python document_id_from_seed
pub fn document_id_from_seed(seed: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(seed.as_bytes());
    let result = hasher.finalize();
    hex::encode(&result[..10]) // First 20 hex chars (10 bytes)
}

/// Firestore REST API client
pub struct FirestoreService {
    client: Client,
    project_id: String,
    access_token: Option<String>,
}

impl FirestoreService {
    /// Create a new Firestore service
    pub async fn new(project_id: String) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let client = Client::new();

        // Try to get access token from metadata server (when running on GCP)
        // or from GOOGLE_APPLICATION_CREDENTIALS
        let access_token = Self::get_access_token().await.ok();

        Ok(Self {
            client,
            project_id,
            access_token,
        })
    }

    /// Get access token from GCP metadata server or service account
    async fn get_access_token() -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        // Try metadata server first (for GKE/Cloud Run)
        let metadata_url =
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";

        let client = Client::new();
        let response = client
            .get(metadata_url)
            .header("Metadata-Flavor", "Google")
            .timeout(std::time::Duration::from_secs(2))
            .send()
            .await;

        if let Ok(resp) = response {
            if resp.status().is_success() {
                #[derive(Deserialize)]
                struct TokenResponse {
                    access_token: String,
                }
                let token: TokenResponse = resp.json().await?;
                return Ok(token.access_token);
            }
        }

        // Fallback: use gcloud CLI token for local development
        let output = tokio::process::Command::new("gcloud")
            .args(["auth", "print-access-token"])
            .output()
            .await?;

        if output.status.success() {
            let token = String::from_utf8(output.stdout)?.trim().to_string();
            return Ok(token);
        }

        Err("Could not get access token".into())
    }

    /// Refresh access token
    pub async fn refresh_token(&mut self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        self.access_token = Some(Self::get_access_token().await?);
        Ok(())
    }

    /// Build Firestore REST API base URL
    fn base_url(&self) -> String {
        format!(
            "https://firestore.googleapis.com/v1/projects/{}/databases/(default)/documents",
            self.project_id
        )
    }

    /// Build request with auth header
    fn build_request(&self, method: reqwest::Method, url: &str) -> reqwest::RequestBuilder {
        let mut req = self.client.request(method, url);
        if let Some(token) = &self.access_token {
            req = req.bearer_auth(token);
        }
        req
    }

    // =========================================================================
    // CONVERSATIONS
    // =========================================================================

    /// Get conversations for a user
    /// Path: users/{uid}/conversations
    pub async fn get_conversations(
        &self,
        uid: &str,
        limit: usize,
        offset: usize,
        include_discarded: bool,
    ) -> Result<Vec<Conversation>, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            CONVERSATIONS_SUBCOLLECTION,
            ""
        );

        // Build structured query
        let query = json!({
            "structuredQuery": {
                "from": [{"collectionId": CONVERSATIONS_SUBCOLLECTION}],
                "where": {
                    "fieldFilter": {
                        "field": {"fieldPath": "discarded"},
                        "op": "EQUAL",
                        "value": {"booleanValue": include_discarded}
                    }
                },
                "orderBy": [{"field": {"fieldPath": "created_at"}, "direction": "DESCENDING"}],
                "limit": limit,
                "offset": offset
            }
        });

        let parent = format!(
            "{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid
        );

        let response = self
            .build_request(reqwest::Method::POST, &format!("{}:runQuery", parent))
            .json(&query)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            tracing::error!("Firestore query error: {}", error_text);
            return Ok(vec![]);
        }

        let results: Vec<Value> = response.json().await?;
        let conversations = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_conversation(d).ok())
            })
            .collect();

        Ok(conversations)
    }

    /// Get a single conversation
    pub async fn get_conversation(
        &self,
        uid: &str,
        conversation_id: &str,
    ) -> Result<Option<Conversation>, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            CONVERSATIONS_SUBCOLLECTION,
            conversation_id
        );

        let response = self
            .build_request(reqwest::Method::GET, &url)
            .send()
            .await?;

        if response.status() == reqwest::StatusCode::NOT_FOUND {
            return Ok(None);
        }

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore error: {}", error_text).into());
        }

        let doc: Value = response.json().await?;
        let conversation = self.parse_conversation(&doc)?;
        Ok(Some(conversation))
    }

    /// Save a conversation
    pub async fn save_conversation(
        &self,
        uid: &str,
        conversation: &Conversation,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            CONVERSATIONS_SUBCOLLECTION,
            conversation.id
        );

        let doc = self.conversation_to_firestore(conversation);

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore save error: {}", error_text).into());
        }

        tracing::info!("Saved conversation {} for user {}", conversation.id, uid);
        Ok(())
    }

    // =========================================================================
    // MEMORIES
    // =========================================================================

    /// Get memories for a user
    /// Copied from Python get_memories
    pub async fn get_memories(
        &self,
        uid: &str,
        limit: usize,
    ) -> Result<Vec<MemoryDB>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!("{}/{}/{}", self.base_url(), USERS_COLLECTION, uid);

        // Query with ordering by scoring DESC
        let query = json!({
            "structuredQuery": {
                "from": [{"collectionId": MEMORIES_SUBCOLLECTION}],
                "orderBy": [
                    {"field": {"fieldPath": "scoring"}, "direction": "DESCENDING"},
                    {"field": {"fieldPath": "created_at"}, "direction": "DESCENDING"}
                ],
                "limit": limit
            }
        });

        let response = self
            .build_request(reqwest::Method::POST, &format!("{}:runQuery", parent))
            .json(&query)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            tracing::error!("Firestore query error: {}", error_text);
            return Ok(vec![]);
        }

        let results: Vec<Value> = response.json().await?;
        let memories = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_memory(d).ok())
            })
            // Filter out rejected memories
            .filter(|m| m.user_review != Some(false))
            .collect();

        Ok(memories)
    }

    /// Save memories to Firestore
    /// Memory IDs are generated from content hash to enable deduplication
    /// Copied from Python save_memories
    pub async fn save_memories(
        &self,
        uid: &str,
        conversation_id: &str,
        memories: &[Memory],
    ) -> Result<Vec<String>, Box<dyn std::error::Error + Send + Sync>> {
        let mut saved_ids = Vec::new();
        let now = Utc::now();

        for memory in memories {
            let memory_id = document_id_from_seed(&memory.content);
            let scoring = MemoryDB::calculate_scoring(&memory.category, &now, false);

            let url = format!(
                "{}/{}/{}/{}/{}",
                self.base_url(),
                USERS_COLLECTION,
                uid,
                MEMORIES_SUBCOLLECTION,
                memory_id
            );

            let doc = json!({
                "fields": {
                    "content": {"stringValue": memory.content},
                    "category": {"stringValue": format!("{:?}", memory.category).to_lowercase()},
                    "created_at": {"timestampValue": now.to_rfc3339()},
                    "updated_at": {"timestampValue": now.to_rfc3339()},
                    "conversation_id": {"stringValue": conversation_id},
                    "reviewed": {"booleanValue": false},
                    "visibility": {"stringValue": "private"},
                    "manually_added": {"booleanValue": false},
                    "scoring": {"stringValue": scoring}
                }
            });

            let response = self
                .build_request(reqwest::Method::PATCH, &url)
                .json(&doc)
                .send()
                .await?;

            if response.status().is_success() {
                saved_ids.push(memory_id);
            } else {
                tracing::warn!("Failed to save memory: {}", response.text().await?);
            }
        }

        tracing::info!(
            "Saved {} memories for conversation {}",
            saved_ids.len(),
            conversation_id
        );
        Ok(saved_ids)
    }

    // =========================================================================
    // ACTION ITEMS
    // =========================================================================

    /// Save action items to Firestore
    /// Copied from Python save_action_items
    pub async fn save_action_items(
        &self,
        uid: &str,
        conversation_id: &str,
        action_items: &[ActionItem],
    ) -> Result<Vec<String>, Box<dyn std::error::Error + Send + Sync>> {
        let mut saved_ids = Vec::new();
        let now = Utc::now();

        for item in action_items {
            let item_id = uuid::Uuid::new_v4().to_string();

            let url = format!(
                "{}/{}/{}/{}/{}",
                self.base_url(),
                USERS_COLLECTION,
                uid,
                ACTION_ITEMS_SUBCOLLECTION,
                item_id
            );

            let mut fields = json!({
                "description": {"stringValue": item.description},
                "completed": {"booleanValue": item.completed},
                "conversation_id": {"stringValue": conversation_id},
                "created_at": {"timestampValue": now.to_rfc3339()}
            });

            if let Some(due_at) = &item.due_at {
                fields["due_at"] = json!({"timestampValue": due_at.to_rfc3339()});
            }

            let doc = json!({"fields": fields});

            let response = self
                .build_request(reqwest::Method::PATCH, &url)
                .json(&doc)
                .send()
                .await?;

            if response.status().is_success() {
                saved_ids.push(item_id);
            } else {
                tracing::warn!("Failed to save action item: {}", response.text().await?);
            }
        }

        tracing::info!(
            "Saved {} action items for conversation {}",
            saved_ids.len(),
            conversation_id
        );
        Ok(saved_ids)
    }

    // =========================================================================
    // PARSING HELPERS
    // =========================================================================

    /// Parse Firestore document to Conversation
    fn parse_conversation(
        &self,
        doc: &Value,
    ) -> Result<Conversation, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc
            .get("fields")
            .ok_or("Missing fields in document")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        Ok(Conversation {
            id,
            created_at: self.parse_timestamp(fields, "created_at")?,
            started_at: self.parse_timestamp(fields, "started_at")?,
            finished_at: self.parse_timestamp(fields, "finished_at")?,
            source: self.parse_string(fields, "source")
                .and_then(|s| serde_json::from_str(&format!("\"{}\"", s)).ok())
                .unwrap_or_default(),
            language: self.parse_string(fields, "language").unwrap_or_default(),
            status: self.parse_string(fields, "status")
                .and_then(|s| serde_json::from_str(&format!("\"{}\"", s)).ok())
                .unwrap_or_default(),
            discarded: self.parse_bool(fields, "discarded").unwrap_or(false),
            structured: self.parse_structured(fields)?,
            transcript_segments: self.parse_transcript_segments(fields)?,
        })
    }

    /// Parse Firestore document to MemoryDB
    fn parse_memory(
        &self,
        doc: &Value,
    ) -> Result<MemoryDB, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        Ok(MemoryDB {
            id: id.clone(),
            uid: "".to_string(), // Not stored in document
            content: self.parse_string(fields, "content").unwrap_or_default(),
            category: self.parse_string(fields, "category")
                .and_then(|s| serde_json::from_str(&format!("\"{}\"", s)).ok())
                .unwrap_or_default(),
            created_at: self.parse_timestamp(fields, "created_at")?,
            updated_at: self.parse_timestamp(fields, "updated_at")?,
            conversation_id: self.parse_string(fields, "conversation_id"),
            reviewed: self.parse_bool(fields, "reviewed").unwrap_or(false),
            user_review: self.parse_bool(fields, "user_review").ok(),
            visibility: self.parse_string(fields, "visibility").unwrap_or_else(|| "private".to_string()),
            manually_added: self.parse_bool(fields, "manually_added").unwrap_or(false),
            scoring: self.parse_string(fields, "scoring"),
        })
    }

    /// Parse structured data from conversation
    fn parse_structured(
        &self,
        fields: &Value,
    ) -> Result<Structured, Box<dyn std::error::Error + Send + Sync>> {
        let structured = fields.get("structured").and_then(|s| s.get("mapValue")).and_then(|m| m.get("fields"));

        if let Some(s) = structured {
            Ok(Structured {
                title: self.parse_string(s, "title").unwrap_or_default(),
                overview: self.parse_string(s, "overview").unwrap_or_default(),
                emoji: self.parse_string(s, "emoji").unwrap_or_else(|| "🧠".to_string()),
                category: self.parse_string(s, "category")
                    .and_then(|c| serde_json::from_str(&format!("\"{}\"", c)).ok())
                    .unwrap_or_default(),
                action_items: vec![], // Parsed separately if needed
                events: vec![],       // Parsed separately if needed
            })
        } else {
            Ok(Structured::default())
        }
    }

    /// Parse transcript segments
    fn parse_transcript_segments(
        &self,
        fields: &Value,
    ) -> Result<Vec<TranscriptSegment>, Box<dyn std::error::Error + Send + Sync>> {
        let segments = fields
            .get("transcript_segments")
            .and_then(|s| s.get("arrayValue"))
            .and_then(|a| a.get("values"))
            .and_then(|v| v.as_array());

        if let Some(segs) = segments {
            Ok(segs
                .iter()
                .filter_map(|seg| {
                    let fields = seg.get("mapValue")?.get("fields")?;
                    Some(TranscriptSegment {
                        text: self.parse_string(fields, "text").unwrap_or_default(),
                        speaker: self.parse_string(fields, "speaker").unwrap_or_else(|| "SPEAKER_00".to_string()),
                        speaker_id: self.parse_int(fields, "speaker_id").unwrap_or(0),
                        is_user: self.parse_bool(fields, "is_user").unwrap_or(false),
                        start: self.parse_float(fields, "start").unwrap_or(0.0),
                        end: self.parse_float(fields, "end").unwrap_or(0.0),
                    })
                })
                .collect())
        } else {
            Ok(vec![])
        }
    }

    /// Convert conversation to Firestore document format
    fn conversation_to_firestore(&self, conv: &Conversation) -> Value {
        json!({
            "fields": {
                "created_at": {"timestampValue": conv.created_at.to_rfc3339()},
                "started_at": {"timestampValue": conv.started_at.to_rfc3339()},
                "finished_at": {"timestampValue": conv.finished_at.to_rfc3339()},
                "source": {"stringValue": format!("{:?}", conv.source).to_lowercase()},
                "language": {"stringValue": conv.language},
                "status": {"stringValue": format!("{:?}", conv.status).to_lowercase()},
                "discarded": {"booleanValue": conv.discarded},
                "structured": {
                    "mapValue": {
                        "fields": {
                            "title": {"stringValue": conv.structured.title},
                            "overview": {"stringValue": conv.structured.overview},
                            "emoji": {"stringValue": conv.structured.emoji},
                            "category": {"stringValue": format!("{:?}", conv.structured.category).to_lowercase()}
                        }
                    }
                },
                "transcript_segments": {
                    "arrayValue": {
                        "values": conv.transcript_segments.iter().map(|seg| {
                            json!({
                                "mapValue": {
                                    "fields": {
                                        "text": {"stringValue": seg.text},
                                        "speaker": {"stringValue": seg.speaker},
                                        "speaker_id": {"integerValue": seg.speaker_id.to_string()},
                                        "is_user": {"booleanValue": seg.is_user},
                                        "start": {"doubleValue": seg.start},
                                        "end": {"doubleValue": seg.end}
                                    }
                                }
                            })
                        }).collect::<Vec<_>>()
                    }
                }
            }
        })
    }

    // Field parsing helpers
    fn parse_string(&self, fields: &Value, key: &str) -> Option<String> {
        fields.get(key)?.get("stringValue")?.as_str().map(|s| s.to_string())
    }

    fn parse_bool(&self, fields: &Value, key: &str) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
        fields
            .get(key)
            .and_then(|v| v.get("booleanValue"))
            .and_then(|v| v.as_bool())
            .ok_or_else(|| format!("Missing or invalid bool field: {}", key).into())
    }

    fn parse_int(&self, fields: &Value, key: &str) -> Option<i32> {
        fields
            .get(key)?
            .get("integerValue")?
            .as_str()
            .and_then(|s| s.parse().ok())
    }

    fn parse_float(&self, fields: &Value, key: &str) -> Option<f64> {
        fields.get(key)?.get("doubleValue")?.as_f64()
    }

    fn parse_timestamp(
        &self,
        fields: &Value,
        key: &str,
    ) -> Result<DateTime<Utc>, Box<dyn std::error::Error + Send + Sync>> {
        let ts = fields
            .get(key)
            .and_then(|v| v.get("timestampValue"))
            .and_then(|v| v.as_str())
            .ok_or_else(|| format!("Missing timestamp field: {}", key))?;

        DateTime::parse_from_rfc3339(ts)
            .map(|dt| dt.with_timezone(&Utc))
            .map_err(|e| format!("Invalid timestamp {}: {}", key, e).into())
    }
}

impl Default for Structured {
    fn default() -> Self {
        Self {
            title: String::new(),
            overview: String::new(),
            emoji: "🧠".to_string(),
            category: Category::Other,
            action_items: vec![],
            events: vec![],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_document_id_from_seed() {
        let id = document_id_from_seed("test content");
        assert_eq!(id.len(), 20);
        assert_eq!(id, document_id_from_seed("test content"));
        assert_ne!(id, document_id_from_seed("different content"));
    }
}
