// Firestore service - Port from Python backend (database.py)
// Uses Firestore REST API for simplicity and compatibility

use chrono::{DateTime, Utc};
use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use tokio::sync::RwLock;

use crate::models::{
    ActionItem, Category, Conversation, ConversationSource, ConversationStatus, Event, Memory,
    MemoryCategory, MemoryDB, Structured, TranscriptSegment,
};

/// Service account credentials from JSON file
#[derive(Debug, Clone, Deserialize)]
struct ServiceAccountCredentials {
    client_email: String,
    private_key: String,
    token_uri: Option<String>,
}

/// JWT claims for Google OAuth2
#[derive(Debug, Serialize)]
struct GoogleJwtClaims {
    iss: String,      // Service account email
    scope: String,    // OAuth scopes
    aud: String,      // Token endpoint
    iat: i64,         // Issued at
    exp: i64,         // Expiration
}

/// Cached access token with expiration
struct CachedToken {
    token: String,
    expires_at: i64,
}

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
    credentials: Option<ServiceAccountCredentials>,
    cached_token: Arc<RwLock<Option<CachedToken>>>,
}

impl FirestoreService {
    /// Create a new Firestore service
    pub async fn new(project_id: String) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let client = Client::new();

        // Load service account credentials from GOOGLE_APPLICATION_CREDENTIALS
        let credentials = Self::load_credentials()?;

        let service = Self {
            client,
            project_id,
            credentials,
            cached_token: Arc::new(RwLock::new(None)),
        };

        // Pre-fetch an access token
        if let Err(e) = service.get_access_token().await {
            tracing::warn!("Failed to get initial access token: {}", e);
        }

        Ok(service)
    }

    /// Load service account credentials from JSON file
    fn load_credentials() -> Result<Option<ServiceAccountCredentials>, Box<dyn std::error::Error + Send + Sync>> {
        // Check GOOGLE_APPLICATION_CREDENTIALS environment variable
        let creds_path = match std::env::var("GOOGLE_APPLICATION_CREDENTIALS") {
            Ok(path) => path,
            Err(_) => {
                // Try default location in current directory
                if std::path::Path::new("google-credentials.json").exists() {
                    "google-credentials.json".to_string()
                } else {
                    tracing::warn!("No GOOGLE_APPLICATION_CREDENTIALS set and no google-credentials.json found");
                    return Ok(None);
                }
            }
        };

        tracing::info!("Loading service account credentials from: {}", creds_path);

        let creds_json = std::fs::read_to_string(&creds_path)
            .map_err(|e| format!("Failed to read credentials file {}: {}", creds_path, e))?;

        let credentials: ServiceAccountCredentials = serde_json::from_str(&creds_json)
            .map_err(|e| format!("Failed to parse credentials JSON: {}", e))?;

        tracing::info!("Loaded credentials for service account: {}", credentials.client_email);

        Ok(Some(credentials))
    }

    /// Get access token, using cache if valid or refreshing if needed
    async fn get_access_token(&self) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        // Check cached token
        {
            let cache = self.cached_token.read().await;
            if let Some(cached) = cache.as_ref() {
                let now = Utc::now().timestamp();
                // Use token if it has at least 60 seconds left
                if cached.expires_at > now + 60 {
                    return Ok(cached.token.clone());
                }
            }
        }

        // Need to refresh token
        let token = self.fetch_new_access_token().await?;

        // Cache it (tokens are valid for 1 hour, we'll refresh after 55 minutes)
        {
            let mut cache = self.cached_token.write().await;
            *cache = Some(CachedToken {
                token: token.clone(),
                expires_at: Utc::now().timestamp() + 3300, // 55 minutes
            });
        }

        Ok(token)
    }

    /// Fetch a new access token from Google OAuth
    async fn fetch_new_access_token(&self) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        // Try metadata server first (for GKE/Cloud Run)
        if let Ok(token) = self.try_metadata_server().await {
            tracing::info!("Got access token from GCP metadata server");
            return Ok(token);
        }

        // Use service account credentials
        if let Some(creds) = &self.credentials {
            let token = self.get_token_from_service_account(creds).await?;
            tracing::info!("Got access token from service account");
            return Ok(token);
        }

        Err("No valid authentication method available. Set GOOGLE_APPLICATION_CREDENTIALS or run on GCP.".into())
    }

    /// Try to get token from GCP metadata server
    async fn try_metadata_server(&self) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        let metadata_url =
            "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";

        let response = self.client
            .get(metadata_url)
            .header("Metadata-Flavor", "Google")
            .timeout(std::time::Duration::from_secs(2))
            .send()
            .await?;

        if response.status().is_success() {
            #[derive(Deserialize)]
            struct TokenResponse {
                access_token: String,
            }
            let token: TokenResponse = response.json().await?;
            return Ok(token.access_token);
        }

        Err("Metadata server not available".into())
    }

    /// Get access token using service account credentials (OAuth2 JWT flow)
    async fn get_token_from_service_account(
        &self,
        creds: &ServiceAccountCredentials,
    ) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        let now = Utc::now().timestamp();
        let token_uri = creds.token_uri.as_deref().unwrap_or("https://oauth2.googleapis.com/token");

        // Create JWT claims
        let claims = GoogleJwtClaims {
            iss: creds.client_email.clone(),
            scope: "https://www.googleapis.com/auth/datastore https://www.googleapis.com/auth/cloud-platform".to_string(),
            aud: token_uri.to_string(),
            iat: now,
            exp: now + 3600, // 1 hour
        };

        // Sign JWT with service account private key (RS256)
        let key = EncodingKey::from_rsa_pem(creds.private_key.as_bytes())
            .map_err(|e| format!("Failed to parse private key: {}", e))?;

        let jwt = encode(&Header::new(Algorithm::RS256), &claims, &key)
            .map_err(|e| format!("Failed to encode JWT: {}", e))?;

        // Exchange JWT for access token
        let response = self.client
            .post(token_uri)
            .form(&[
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", &jwt),
            ])
            .send()
            .await
            .map_err(|e| format!("Token request failed: {}", e))?;

        if !response.status().is_success() {
            let error_text = response.text().await.unwrap_or_default();
            return Err(format!("Token exchange failed: {}", error_text).into());
        }

        #[derive(Deserialize)]
        struct TokenResponse {
            access_token: String,
        }

        let token_response: TokenResponse = response.json().await
            .map_err(|e| format!("Failed to parse token response: {}", e))?;

        Ok(token_response.access_token)
    }

    /// Refresh access token (for manual refresh if needed)
    pub async fn refresh_token(&self) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // Clear cache to force refresh
        {
            let mut cache = self.cached_token.write().await;
            *cache = None;
        }
        self.get_access_token().await?;
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
    async fn build_request(&self, method: reqwest::Method, url: &str) -> Result<reqwest::RequestBuilder, Box<dyn std::error::Error + Send + Sync>> {
        let mut req = self.client.request(method, url);
        let token = self.get_access_token().await?;
        req = req.bearer_auth(token);
        Ok(req)
    }

    // =========================================================================
    // CONVERSATIONS
    // =========================================================================

    /// Get conversations for a user
    /// Path: users/{uid}/conversations
    /// Ported from Python: database/conversations.py get_conversations()
    pub async fn get_conversations(
        &self,
        uid: &str,
        limit: usize,
        offset: usize,
        include_discarded: bool,
        statuses: &[String],
    ) -> Result<Vec<Conversation>, Box<dyn std::error::Error + Send + Sync>> {
        // Build filters array (match Python behavior)
        let mut filters: Vec<Value> = Vec::new();

        // Python: if not include_discarded: where(discarded == False)
        // Only filter when include_discarded is false
        if !include_discarded {
            filters.push(json!({
                "fieldFilter": {
                    "field": {"fieldPath": "discarded"},
                    "op": "EQUAL",
                    "value": {"booleanValue": false}
                }
            }));
        }

        // Python: if len(statuses) > 0: where(status in statuses)
        if !statuses.is_empty() {
            filters.push(json!({
                "fieldFilter": {
                    "field": {"fieldPath": "status"},
                    "op": "IN",
                    "value": {
                        "arrayValue": {
                            "values": statuses.iter().map(|s| json!({"stringValue": s})).collect::<Vec<_>>()
                        }
                    }
                }
            }));
        }

        // Build the where clause based on number of filters
        let where_clause = if filters.is_empty() {
            None
        } else if filters.len() == 1 {
            Some(filters.into_iter().next().unwrap())
        } else {
            // Multiple filters need compositeFilter with AND
            Some(json!({
                "compositeFilter": {
                    "op": "AND",
                    "filters": filters
                }
            }))
        };

        // Build structured query
        let mut structured_query = json!({
            "from": [{"collectionId": CONVERSATIONS_SUBCOLLECTION}],
            "orderBy": [{"field": {"fieldPath": "created_at"}, "direction": "DESCENDING"}],
            "limit": limit,
            "offset": offset
        });

        if let Some(where_filter) = where_clause {
            structured_query["where"] = where_filter;
        }

        let query = json!({
            "structuredQuery": structured_query
        });

        let parent = format!(
            "{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid
        );

        tracing::debug!("Firestore query: {}", serde_json::to_string_pretty(&query).unwrap_or_default());

        let response = self
            .build_request(reqwest::Method::POST, &format!("{}:runQuery", parent))
            .await?
            .json(&query)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            tracing::error!("Firestore query error: {}", error_text);
            return Err(format!("Firestore query failed: {}", error_text).into());
        }

        let results: Vec<Value> = response.json().await?;
        let conversations: Vec<Conversation> = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| match self.parse_conversation(d) {
                        Ok(conv) => Some(conv),
                        Err(e) => {
                            tracing::warn!("Failed to parse conversation: {}", e);
                            None
                        }
                    })
            })
            .collect();

        tracing::info!("Retrieved {} conversations for user {}", conversations.len(), uid);
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
            .await?
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
            .await?
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
            .await?
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
                .await?
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
                .await?
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

        // Use created_at as fallback for missing timestamps
        let created_at = self.parse_timestamp_optional(fields, "created_at")
            .unwrap_or_else(Utc::now);
        let started_at = self.parse_timestamp_optional(fields, "started_at")
            .unwrap_or(created_at);
        let finished_at = self.parse_timestamp_optional(fields, "finished_at")
            .unwrap_or(created_at);

        Ok(Conversation {
            id,
            created_at,
            started_at,
            finished_at,
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
    /// Note: Python stores segments as encrypted+compressed strings for enhanced protection.
    /// This implementation handles plain arrays; encrypted segments return empty vec.
    /// TODO: Implement decryption for full parity with Python backend.
    fn parse_transcript_segments(
        &self,
        fields: &Value,
    ) -> Result<Vec<TranscriptSegment>, Box<dyn std::error::Error + Send + Sync>> {
        let transcript_field = fields.get("transcript_segments");

        // Check if transcript is a string (encrypted/compressed) - not yet supported
        if let Some(string_val) = transcript_field.and_then(|t| t.get("stringValue")) {
            tracing::debug!("Transcript segments are encrypted/compressed (string format), returning empty");
            return Ok(vec![]);
        }

        // Check if transcript is bytes (compressed) - not yet supported
        if let Some(bytes_val) = transcript_field.and_then(|t| t.get("bytesValue")) {
            tracing::debug!("Transcript segments are compressed (bytes format), returning empty");
            return Ok(vec![]);
        }

        // Handle plain array format
        let segments = transcript_field
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

    fn parse_timestamp_optional(&self, fields: &Value, key: &str) -> Option<DateTime<Utc>> {
        fields
            .get(key)
            .and_then(|v| v.get("timestampValue"))
            .and_then(|v| v.as_str())
            .and_then(|ts| DateTime::parse_from_rfc3339(ts).ok())
            .map(|dt| dt.with_timezone(&Utc))
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
