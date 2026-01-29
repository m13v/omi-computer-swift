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
    ActionItem, ActionItemDB, App, AppReview, AppSummary, Category, ChatSession, Conversation,
    ConversationSource, ConversationStatus, DailySummarySettings, Event, Memory, MemoryCategory,
    MemoryDB, Message, MessageSender, MessageType, NotificationSettings, Structured,
    TranscriptSegment, TranscriptionPreferences, UserProfile,
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
pub const APPS_COLLECTION: &str = "plugins_data";
pub const ENABLED_APPS_SUBCOLLECTION: &str = "enabled_plugins";
pub const MESSAGES_SUBCOLLECTION: &str = "messages";
pub const CHAT_SESSIONS_SUBCOLLECTION: &str = "chat_sessions";

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

    /// Add an app result to a conversation
    pub async fn add_app_result(
        &self,
        uid: &str,
        conversation_id: &str,
        app_id: &str,
        content: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // First get the current conversation to append to apps_results
        let current = self.get_conversation(uid, conversation_id).await?;
        let mut apps_results = current
            .map(|c| c.apps_results)
            .unwrap_or_default();

        // Remove existing result for this app if present, then add new one
        apps_results.retain(|r| r.app_id.as_deref() != Some(app_id));
        apps_results.push(crate::models::AppResult {
            app_id: Some(app_id.to_string()),
            content: content.to_string(),
        });

        // Build the update document
        let url = format!(
            "{}/{}/{}/{}/{}?updateMask.fieldPaths=apps_results",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            CONVERSATIONS_SUBCOLLECTION,
            conversation_id
        );

        let apps_results_value: Vec<Value> = apps_results
            .iter()
            .map(|r| {
                json!({
                    "mapValue": {
                        "fields": {
                            "app_id": { "stringValue": r.app_id.as_deref().unwrap_or("") },
                            "content": { "stringValue": &r.content }
                        }
                    }
                })
            })
            .collect();

        let doc = json!({
            "fields": {
                "apps_results": {
                    "arrayValue": {
                        "values": apps_results_value
                    }
                }
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore update error: {}", error_text).into());
        }

        tracing::info!("Added app result for app {} to conversation {}", app_id, conversation_id);
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

    /// Get a single memory by ID
    pub async fn get_memory(
        &self,
        uid: &str,
        memory_id: &str,
    ) -> Result<Option<MemoryDB>, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            MEMORIES_SUBCOLLECTION,
            memory_id
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
        let memory = self.parse_memory(&doc)?;
        Ok(Some(memory))
    }

    /// Delete a memory by ID
    pub async fn delete_memory(
        &self,
        uid: &str,
        memory_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            MEMORIES_SUBCOLLECTION,
            memory_id
        );

        let response = self
            .build_request(reqwest::Method::DELETE, &url)
            .await?
            .send()
            .await?;

        if !response.status().is_success() && response.status() != reqwest::StatusCode::NOT_FOUND {
            let error_text = response.text().await?;
            return Err(format!("Firestore delete error: {}", error_text).into());
        }

        tracing::info!("Deleted memory {} for user {}", memory_id, uid);
        Ok(())
    }

    /// Update memory content
    pub async fn update_memory_content(
        &self,
        uid: &str,
        memory_id: &str,
        content: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}?updateMask.fieldPaths=content&updateMask.fieldPaths=updated_at",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            MEMORIES_SUBCOLLECTION,
            memory_id
        );

        let now = Utc::now();
        let doc = json!({
            "fields": {
                "content": {"stringValue": content},
                "updated_at": {"timestampValue": now.to_rfc3339()}
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore update error: {}", error_text).into());
        }

        tracing::info!("Updated memory content {} for user {}", memory_id, uid);
        Ok(())
    }

    /// Update memory visibility
    pub async fn update_memory_visibility(
        &self,
        uid: &str,
        memory_id: &str,
        visibility: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}?updateMask.fieldPaths=visibility&updateMask.fieldPaths=updated_at",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            MEMORIES_SUBCOLLECTION,
            memory_id
        );

        let now = Utc::now();
        let doc = json!({
            "fields": {
                "visibility": {"stringValue": visibility},
                "updated_at": {"timestampValue": now.to_rfc3339()}
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore update error: {}", error_text).into());
        }

        tracing::info!("Updated memory visibility {} for user {}", memory_id, uid);
        Ok(())
    }

    /// Review a memory (approve/reject)
    pub async fn review_memory(
        &self,
        uid: &str,
        memory_id: &str,
        value: bool,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}?updateMask.fieldPaths=reviewed&updateMask.fieldPaths=user_review&updateMask.fieldPaths=updated_at",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            MEMORIES_SUBCOLLECTION,
            memory_id
        );

        let now = Utc::now();
        let doc = json!({
            "fields": {
                "reviewed": {"booleanValue": true},
                "user_review": {"booleanValue": value},
                "updated_at": {"timestampValue": now.to_rfc3339()}
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore update error: {}", error_text).into());
        }

        tracing::info!("Reviewed memory {} for user {} with value {}", memory_id, uid, value);
        Ok(())
    }

    /// Create a manual memory
    pub async fn create_manual_memory(
        &self,
        uid: &str,
        content: &str,
        visibility: &str,
    ) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        let memory_id = document_id_from_seed(content);
        let now = Utc::now();
        let scoring = MemoryDB::calculate_scoring(&MemoryCategory::Manual, &now, true);

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
                "content": {"stringValue": content},
                "category": {"stringValue": "manual"},
                "created_at": {"timestampValue": now.to_rfc3339()},
                "updated_at": {"timestampValue": now.to_rfc3339()},
                "reviewed": {"booleanValue": true},
                "user_review": {"booleanValue": true},
                "visibility": {"stringValue": visibility},
                "manually_added": {"booleanValue": true},
                "scoring": {"stringValue": scoring}
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore create error: {}", error_text).into());
        }

        tracing::info!("Created manual memory {} for user {}", memory_id, uid);
        Ok(memory_id)
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

    /// Get action items for a user
    /// Path: users/{uid}/action_items
    pub async fn get_action_items(
        &self,
        uid: &str,
        limit: usize,
        offset: usize,
        completed_filter: Option<bool>,
    ) -> Result<Vec<ActionItemDB>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!("{}/{}/{}", self.base_url(), USERS_COLLECTION, uid);

        // Build filters
        let mut filters: Vec<Value> = Vec::new();

        if let Some(completed) = completed_filter {
            filters.push(json!({
                "fieldFilter": {
                    "field": {"fieldPath": "completed"},
                    "op": "EQUAL",
                    "value": {"booleanValue": completed}
                }
            }));
        }

        // Build the where clause
        let where_clause = if filters.is_empty() {
            None
        } else if filters.len() == 1 {
            Some(filters.into_iter().next().unwrap())
        } else {
            Some(json!({
                "compositeFilter": {
                    "op": "AND",
                    "filters": filters
                }
            }))
        };

        // Build structured query
        let mut structured_query = json!({
            "from": [{"collectionId": ACTION_ITEMS_SUBCOLLECTION}],
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
        let action_items = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_action_item(d).ok())
            })
            .collect();

        Ok(action_items)
    }

    /// Update an action item
    pub async fn update_action_item(
        &self,
        uid: &str,
        item_id: &str,
        completed: Option<bool>,
        description: Option<&str>,
        due_at: Option<DateTime<Utc>>,
    ) -> Result<ActionItemDB, Box<dyn std::error::Error + Send + Sync>> {
        // Build update mask and fields
        let mut field_paths: Vec<&str> = vec!["updated_at"];
        let mut fields = json!({
            "updated_at": {"timestampValue": Utc::now().to_rfc3339()}
        });

        if let Some(c) = completed {
            field_paths.push("completed");
            fields["completed"] = json!({"booleanValue": c});

            // Set completed_at if completing the item
            if c {
                field_paths.push("completed_at");
                fields["completed_at"] = json!({"timestampValue": Utc::now().to_rfc3339()});
            }
        }

        if let Some(d) = description {
            field_paths.push("description");
            fields["description"] = json!({"stringValue": d});
        }

        if let Some(due) = due_at {
            field_paths.push("due_at");
            fields["due_at"] = json!({"timestampValue": due.to_rfc3339()});
        }

        let update_mask = field_paths
            .iter()
            .map(|p| format!("updateMask.fieldPaths={}", p))
            .collect::<Vec<_>>()
            .join("&");

        let url = format!(
            "{}/{}/{}/{}/{}?{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            ACTION_ITEMS_SUBCOLLECTION,
            item_id,
            update_mask
        );

        let doc = json!({"fields": fields});

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore update error: {}", error_text).into());
        }

        // Parse and return the updated document
        let updated_doc: Value = response.json().await?;
        let action_item = self.parse_action_item(&updated_doc)?;

        tracing::info!("Updated action item {} for user {}", item_id, uid);
        Ok(action_item)
    }

    /// Delete an action item
    pub async fn delete_action_item(
        &self,
        uid: &str,
        item_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            ACTION_ITEMS_SUBCOLLECTION,
            item_id
        );

        let response = self
            .build_request(reqwest::Method::DELETE, &url)
            .await?
            .send()
            .await?;

        if !response.status().is_success() && response.status() != reqwest::StatusCode::NOT_FOUND {
            let error_text = response.text().await?;
            return Err(format!("Firestore delete error: {}", error_text).into());
        }

        tracing::info!("Deleted action item {} for user {}", item_id, uid);
        Ok(())
    }

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

    /// Create a single action item (for API/desktop creation)
    pub async fn create_action_item(
        &self,
        uid: &str,
        description: &str,
        due_at: Option<DateTime<Utc>>,
        source: Option<&str>,
        priority: Option<&str>,
        metadata: Option<&str>,
    ) -> Result<ActionItemDB, Box<dyn std::error::Error + Send + Sync>> {
        let item_id = uuid::Uuid::new_v4().to_string();
        let now = Utc::now();

        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            ACTION_ITEMS_SUBCOLLECTION,
            item_id
        );

        let mut fields = json!({
            "description": {"stringValue": description},
            "completed": {"booleanValue": false},
            "created_at": {"timestampValue": now.to_rfc3339()}
        });

        if let Some(due) = due_at {
            fields["due_at"] = json!({"timestampValue": due.to_rfc3339()});
        }

        if let Some(src) = source {
            fields["source"] = json!({"stringValue": src});
        }

        if let Some(pri) = priority {
            fields["priority"] = json!({"stringValue": pri});
        }

        if let Some(meta) = metadata {
            fields["metadata"] = json!({"stringValue": meta});
        }

        let doc = json!({"fields": fields});

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore create error: {}", error_text).into());
        }

        // Parse and return the created document
        let created_doc: Value = response.json().await?;
        let action_item = self.parse_action_item(&created_doc)?;

        tracing::info!(
            "Created action item {} for user {} with source={:?}",
            item_id,
            uid,
            source
        );
        Ok(action_item)
    }

    // =========================================================================
    // APPS
    // =========================================================================

    /// Get all apps with optional filters
    pub async fn get_apps(
        &self,
        uid: &str,
        limit: usize,
        offset: usize,
        capability: Option<&str>,
        category: Option<&str>,
    ) -> Result<Vec<AppSummary>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = self.base_url();

        // Build filters
        let mut filters: Vec<Value> = vec![
            // Only approved apps
            json!({
                "fieldFilter": {
                    "field": {"fieldPath": "approved"},
                    "op": "EQUAL",
                    "value": {"booleanValue": true}
                }
            }),
        ];

        if let Some(cat) = category {
            filters.push(json!({
                "fieldFilter": {
                    "field": {"fieldPath": "category"},
                    "op": "EQUAL",
                    "value": {"stringValue": cat}
                }
            }));
        }

        // Build where clause
        let where_clause = if filters.len() == 1 {
            filters.into_iter().next()
        } else {
            Some(json!({
                "compositeFilter": {
                    "op": "AND",
                    "filters": filters
                }
            }))
        };

        let mut structured_query = json!({
            "from": [{"collectionId": APPS_COLLECTION}],
            "orderBy": [{"field": {"fieldPath": "installs"}, "direction": "DESCENDING"}],
            "limit": limit,
            "offset": offset
        });

        if let Some(where_filter) = where_clause {
            structured_query["where"] = where_filter;
        }

        let query = json!({
            "structuredQuery": structured_query
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

        // Get user's enabled apps to mark them
        let enabled_app_ids = self.get_enabled_app_ids(uid).await.unwrap_or_default();

        let mut apps: Vec<AppSummary> = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_app_summary(d).ok())
            })
            .collect();

        // Filter by capability if specified
        if let Some(cap) = capability {
            apps.retain(|app| app.capabilities.contains(&cap.to_string()));
        }

        // Mark enabled apps
        for app in &mut apps {
            app.enabled = enabled_app_ids.contains(&app.id);
        }

        Ok(apps)
    }

    /// Get approved public apps
    pub async fn get_approved_apps(
        &self,
        uid: &str,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<AppSummary>, Box<dyn std::error::Error + Send + Sync>> {
        self.get_apps(uid, limit, offset, None, None).await
    }

    /// Get popular apps (sorted by installs and rating)
    pub async fn get_popular_apps(
        &self,
        uid: &str,
        limit: usize,
    ) -> Result<Vec<AppSummary>, Box<dyn std::error::Error + Send + Sync>> {
        let mut apps = self.get_apps(uid, limit * 2, 0, None, None).await?;

        // Sort by popularity score: ((rating_avg / 5)^2) * log(1 + rating_count) * sqrt(log(1 + installs))
        apps.sort_by(|a, b| {
            let score_a = Self::calculate_popularity_score(a);
            let score_b = Self::calculate_popularity_score(b);
            score_b.partial_cmp(&score_a).unwrap_or(std::cmp::Ordering::Equal)
        });

        apps.truncate(limit);
        Ok(apps)
    }

    fn calculate_popularity_score(app: &AppSummary) -> f64 {
        let rating = app.rating_avg.unwrap_or(3.0);
        let rating_factor = (rating / 5.0).powi(2);
        let count_factor = (1.0 + app.rating_count as f64).ln();
        let installs_factor = (1.0 + app.installs as f64).ln().sqrt();
        rating_factor * count_factor * installs_factor
    }

    /// Search apps with filters
    pub async fn search_apps(
        &self,
        uid: &str,
        query: Option<&str>,
        category: Option<&str>,
        capability: Option<&str>,
        min_rating: Option<i32>,
        my_apps: bool,
        installed_only: bool,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<AppSummary>, Box<dyn std::error::Error + Send + Sync>> {
        // Start with all apps
        let mut apps = self.get_apps(uid, 500, 0, capability, category).await?;

        // Filter by query (name/description)
        if let Some(q) = query {
            let q_lower = q.to_lowercase();
            apps.retain(|app| {
                app.name.to_lowercase().contains(&q_lower)
                    || app.description.to_lowercase().contains(&q_lower)
            });
        }

        // Filter by minimum rating
        if let Some(min) = min_rating {
            apps.retain(|app| app.rating_avg.unwrap_or(0.0) >= min as f64);
        }

        // Filter by my apps (apps owned by the user)
        if my_apps {
            // For now, we don't have uid in AppSummary, so skip this filter
            // In a full implementation, we'd need to check app.uid == uid
        }

        // Filter by installed only
        if installed_only {
            apps.retain(|app| app.enabled);
        }

        // Apply pagination
        let start = offset.min(apps.len());
        let end = (offset + limit).min(apps.len());
        Ok(apps[start..end].to_vec())
    }

    /// Get a single app by ID
    pub async fn get_app(
        &self,
        uid: &str,
        app_id: &str,
    ) -> Result<Option<App>, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!("{}/{}/{}", self.base_url(), APPS_COLLECTION, app_id);

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
        let mut app = self.parse_app(&doc)?;

        // Check if enabled for user
        let enabled_ids = self.get_enabled_app_ids(uid).await.unwrap_or_default();
        app.enabled = enabled_ids.contains(&app.id);

        Ok(Some(app))
    }

    /// Get reviews for an app
    pub async fn get_app_reviews(
        &self,
        app_id: &str,
    ) -> Result<Vec<AppReview>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!("{}/{}/{}", self.base_url(), APPS_COLLECTION, app_id);

        let query = json!({
            "structuredQuery": {
                "from": [{"collectionId": "reviews"}],
                "orderBy": [{"field": {"fieldPath": "rated_at"}, "direction": "DESCENDING"}],
                "limit": 100
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
        let reviews = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_app_review(d).ok())
            })
            .collect();

        Ok(reviews)
    }

    /// Enable an app for a user
    pub async fn enable_app(
        &self,
        uid: &str,
        app_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            ENABLED_APPS_SUBCOLLECTION,
            app_id
        );

        let now = Utc::now();
        let doc = json!({
            "fields": {
                "app_id": {"stringValue": app_id},
                "enabled_at": {"timestampValue": now.to_rfc3339()}
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Failed to enable app: {}", error_text).into());
        }

        // Increment install count on the app
        self.increment_app_installs(app_id).await?;

        tracing::info!("Enabled app {} for user {}", app_id, uid);
        Ok(())
    }

    /// Disable an app for a user
    pub async fn disable_app(
        &self,
        uid: &str,
        app_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            ENABLED_APPS_SUBCOLLECTION,
            app_id
        );

        let response = self
            .build_request(reqwest::Method::DELETE, &url)
            .await?
            .send()
            .await?;

        if !response.status().is_success() && response.status() != reqwest::StatusCode::NOT_FOUND {
            let error_text = response.text().await?;
            return Err(format!("Failed to disable app: {}", error_text).into());
        }

        tracing::info!("Disabled app {} for user {}", app_id, uid);
        Ok(())
    }

    /// Get user's enabled app IDs
    async fn get_enabled_app_ids(
        &self,
        uid: &str,
    ) -> Result<Vec<String>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!("{}/{}/{}", self.base_url(), USERS_COLLECTION, uid);

        let query = json!({
            "structuredQuery": {
                "from": [{"collectionId": ENABLED_APPS_SUBCOLLECTION}],
                "limit": 500
            }
        });

        let response = self
            .build_request(reqwest::Method::POST, &format!("{}:runQuery", parent))
            .await?
            .json(&query)
            .send()
            .await?;

        if !response.status().is_success() {
            return Ok(vec![]);
        }

        let results: Vec<Value> = response.json().await?;
        let ids = results
            .into_iter()
            .filter_map(|doc| {
                let d = doc.get("document")?;
                let name = d.get("name")?.as_str()?;
                Some(name.split('/').last()?.to_string())
            })
            .collect();

        Ok(ids)
    }

    /// Get user's enabled apps with full details
    pub async fn get_enabled_apps(
        &self,
        uid: &str,
    ) -> Result<Vec<AppSummary>, Box<dyn std::error::Error + Send + Sync>> {
        let enabled_ids = self.get_enabled_app_ids(uid).await?;

        let mut apps = Vec::new();
        for app_id in enabled_ids {
            if let Ok(Some(app)) = self.get_app(uid, &app_id).await {
                let mut summary = AppSummary::from(app);
                summary.enabled = true;
                apps.push(summary);
            }
        }

        Ok(apps)
    }

    /// Increment app install count
    async fn increment_app_installs(
        &self,
        app_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        // First get current installs
        let app = match self.get_app("", app_id).await? {
            Some(a) => a,
            None => return Ok(()),
        };

        let new_installs = app.installs + 1;

        let url = format!(
            "{}/{}/{}?updateMask.fieldPaths=installs",
            self.base_url(),
            APPS_COLLECTION,
            app_id
        );

        let doc = json!({
            "fields": {
                "installs": {"integerValue": new_installs.to_string()}
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            tracing::warn!("Failed to increment app installs: {}", response.text().await?);
        }

        Ok(())
    }

    /// Submit a review for an app
    pub async fn submit_app_review(
        &self,
        uid: &str,
        app_id: &str,
        score: i32,
        review: &str,
    ) -> Result<AppReview, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/reviews/{}",
            self.base_url(),
            APPS_COLLECTION,
            app_id,
            uid
        );

        let now = Utc::now();
        let doc = json!({
            "fields": {
                "uid": {"stringValue": uid},
                "score": {"integerValue": score.to_string()},
                "review": {"stringValue": review},
                "rated_at": {"timestampValue": now.to_rfc3339()}
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Failed to submit review: {}", error_text).into());
        }

        // Update app's rating average and count
        self.update_app_rating(app_id).await?;

        Ok(AppReview {
            uid: uid.to_string(),
            score,
            review: review.to_string(),
            response: None,
            rated_at: now,
            edited_at: None,
        })
    }

    /// Update app's rating average and count
    async fn update_app_rating(
        &self,
        app_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let reviews = self.get_app_reviews(app_id).await?;

        if reviews.is_empty() {
            return Ok(());
        }

        let total: i32 = reviews.iter().map(|r| r.score).sum();
        let count = reviews.len() as i32;
        let avg = total as f64 / count as f64;

        let url = format!(
            "{}/{}/{}?updateMask.fieldPaths=rating_avg&updateMask.fieldPaths=rating_count",
            self.base_url(),
            APPS_COLLECTION,
            app_id
        );

        let doc = json!({
            "fields": {
                "rating_avg": {"doubleValue": avg},
                "rating_count": {"integerValue": count.to_string()}
            }
        });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            tracing::warn!("Failed to update app rating: {}", response.text().await?);
        }

        Ok(())
    }

    /// Parse Firestore document to App
    fn parse_app(
        &self,
        doc: &Value,
    ) -> Result<App, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields in document")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        Ok(App {
            id,
            name: self.parse_string(fields, "name").unwrap_or_default(),
            description: self.parse_string(fields, "description").unwrap_or_default(),
            image: self.parse_string(fields, "image").unwrap_or_default(),
            category: self.parse_string(fields, "category").unwrap_or_else(|| "other".to_string()),
            author: self.parse_string(fields, "author").unwrap_or_default(),
            email: self.parse_string(fields, "email"),
            capabilities: self.parse_string_array(fields, "capabilities"),
            uid: self.parse_string(fields, "uid"),
            approved: self.parse_bool(fields, "approved").unwrap_or(false),
            private: self.parse_bool(fields, "private").unwrap_or(false),
            status: self.parse_string(fields, "status").unwrap_or_else(|| "under-review".to_string()),
            chat_prompt: self.parse_string(fields, "chat_prompt"),
            memory_prompt: self.parse_string(fields, "memory_prompt"),
            persona_prompt: self.parse_string(fields, "persona_prompt"),
            external_integration: None, // TODO: Parse nested object
            proactive_notification: None, // TODO: Parse nested object
            chat_tools: vec![], // TODO: Parse array of nested objects
            installs: self.parse_int(fields, "installs").unwrap_or(0),
            rating_avg: self.parse_float(fields, "rating_avg"),
            rating_count: self.parse_int(fields, "rating_count").unwrap_or(0),
            is_paid: self.parse_bool(fields, "is_paid").unwrap_or(false),
            price: self.parse_float(fields, "price"),
            payment_plan: self.parse_string(fields, "payment_plan"),
            username: self.parse_string(fields, "username"),
            twitter: self.parse_string(fields, "twitter"),
            created_at: self.parse_timestamp_optional(fields, "created_at"),
            enabled: false, // Will be set by caller
        })
    }

    /// Parse Firestore document to AppSummary
    fn parse_app_summary(
        &self,
        doc: &Value,
    ) -> Result<AppSummary, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields in document")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        Ok(AppSummary {
            id,
            name: self.parse_string(fields, "name").unwrap_or_default(),
            description: self.parse_string(fields, "description").unwrap_or_default(),
            image: self.parse_string(fields, "image").unwrap_or_default(),
            category: self.parse_string(fields, "category").unwrap_or_else(|| "other".to_string()),
            author: self.parse_string(fields, "author").unwrap_or_default(),
            capabilities: self.parse_string_array(fields, "capabilities"),
            approved: self.parse_bool(fields, "approved").unwrap_or(false),
            private: self.parse_bool(fields, "private").unwrap_or(false),
            installs: self.parse_int(fields, "installs").unwrap_or(0),
            rating_avg: self.parse_float(fields, "rating_avg"),
            rating_count: self.parse_int(fields, "rating_count").unwrap_or(0),
            is_paid: self.parse_bool(fields, "is_paid").unwrap_or(false),
            price: self.parse_float(fields, "price"),
            enabled: false, // Will be set by caller
        })
    }

    /// Parse Firestore document to AppReview
    fn parse_app_review(
        &self,
        doc: &Value,
    ) -> Result<AppReview, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let uid = name.split('/').last().unwrap_or("").to_string();

        Ok(AppReview {
            uid,
            score: self.parse_int(fields, "score").unwrap_or(0),
            review: self.parse_string(fields, "review").unwrap_or_default(),
            response: self.parse_string(fields, "response"),
            rated_at: self.parse_timestamp_optional(fields, "rated_at").unwrap_or_else(Utc::now),
            edited_at: self.parse_timestamp_optional(fields, "edited_at"),
        })
    }

    /// Parse string array from Firestore
    fn parse_string_array(&self, fields: &Value, key: &str) -> Vec<String> {
        fields
            .get(key)
            .and_then(|v| v.get("arrayValue"))
            .and_then(|a| a.get("values"))
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.get("stringValue")?.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default()
    }

    // =========================================================================
    // CHAT MESSAGES
    // =========================================================================

    /// Get or create a chat session for a user and optional app
    pub async fn get_or_create_chat_session(
        &self,
        uid: &str,
        app_id: Option<&str>,
    ) -> Result<ChatSession, Box<dyn std::error::Error + Send + Sync>> {
        // Try to find existing session
        if let Some(session) = self.get_chat_session(uid, app_id).await? {
            return Ok(session);
        }

        // Create new session
        let session = ChatSession::new(app_id.map(|s| s.to_string()));
        self.create_chat_session(uid, &session).await?;
        Ok(session)
    }

    /// Get chat session for a user and optional app
    pub async fn get_chat_session(
        &self,
        uid: &str,
        app_id: Option<&str>,
    ) -> Result<Option<ChatSession>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!("{}/{}/{}", self.base_url(), USERS_COLLECTION, uid);

        // Build filter for app_id
        let where_clause = match app_id {
            Some(id) => json!({
                "fieldFilter": {
                    "field": {"fieldPath": "app_id"},
                    "op": "EQUAL",
                    "value": {"stringValue": id}
                }
            }),
            None => json!({
                "unaryFilter": {
                    "field": {"fieldPath": "app_id"},
                    "op": "IS_NULL"
                }
            }),
        };

        let query = json!({
            "structuredQuery": {
                "from": [{"collectionId": CHAT_SESSIONS_SUBCOLLECTION}],
                "where": where_clause,
                "orderBy": [{"field": {"fieldPath": "created_at"}, "direction": "DESCENDING"}],
                "limit": 1
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
            return Ok(None);
        }

        let results: Vec<Value> = response.json().await?;
        let session = results
            .into_iter()
            .find_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_chat_session(d).ok())
            });

        Ok(session)
    }

    /// Create a new chat session
    pub async fn create_chat_session(
        &self,
        uid: &str,
        session: &ChatSession,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            CHAT_SESSIONS_SUBCOLLECTION,
            session.id
        );

        let mut fields = json!({
            "created_at": {"timestampValue": session.created_at.to_rfc3339()},
            "message_ids": {
                "arrayValue": {
                    "values": session.message_ids.iter().map(|id| json!({"stringValue": id})).collect::<Vec<_>>()
                }
            }
        });

        if let Some(ref app_id) = session.app_id {
            fields["app_id"] = json!({"stringValue": app_id});
        }

        let doc = json!({"fields": fields});

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Failed to create chat session: {}", error_text).into());
        }

        tracing::info!("Created chat session {} for user {}", session.id, uid);
        Ok(())
    }

    /// Get messages for a user with optional app filter
    pub async fn get_messages(
        &self,
        uid: &str,
        limit: usize,
        app_id: Option<&str>,
    ) -> Result<Vec<Message>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!("{}/{}/{}", self.base_url(), USERS_COLLECTION, uid);

        // Build filter for app_id
        let where_clause = match app_id {
            Some(id) => Some(json!({
                "fieldFilter": {
                    "field": {"fieldPath": "app_id"},
                    "op": "EQUAL",
                    "value": {"stringValue": id}
                }
            })),
            None => None,
        };

        let mut structured_query = json!({
            "from": [{"collectionId": MESSAGES_SUBCOLLECTION}],
            "orderBy": [{"field": {"fieldPath": "created_at"}, "direction": "ASCENDING"}],
            "limit": limit
        });

        if let Some(filter) = where_clause {
            structured_query["where"] = filter;
        }

        let query = json!({
            "structuredQuery": structured_query
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
        let messages = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_message(d).ok())
            })
            .collect();

        Ok(messages)
    }

    /// Add a message for a user
    pub async fn add_message(
        &self,
        uid: &str,
        message: &Message,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            MESSAGES_SUBCOLLECTION,
            message.id
        );

        let mut fields = json!({
            "text": {"stringValue": &message.text},
            "created_at": {"timestampValue": message.created_at.to_rfc3339()},
            "sender": {"stringValue": match message.sender {
                MessageSender::Ai => "ai",
                MessageSender::Human => "human",
            }},
            "type": {"stringValue": match message.message_type {
                MessageType::Text => "text",
                MessageType::DaySummary => "day_summary",
            }},
            "memories_id": {
                "arrayValue": {
                    "values": message.memories_id.iter().map(|id| json!({"stringValue": id})).collect::<Vec<_>>()
                }
            }
        });

        if let Some(ref app_id) = message.app_id {
            fields["app_id"] = json!({"stringValue": app_id});
        }

        if let Some(ref session_id) = message.chat_session_id {
            fields["chat_session_id"] = json!({"stringValue": session_id});
        }

        let doc = json!({"fields": fields});

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Failed to add message: {}", error_text).into());
        }

        tracing::info!("Added message {} for user {}", message.id, uid);
        Ok(())
    }

    /// Delete all messages for a user with optional app filter
    pub async fn delete_messages(
        &self,
        uid: &str,
        app_id: Option<&str>,
    ) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
        // First, get all messages to delete
        let messages = self.get_messages(uid, 1000, app_id).await?;
        let count = messages.len();

        // Delete each message
        for message in messages {
            let url = format!(
                "{}/{}/{}/{}/{}",
                self.base_url(),
                USERS_COLLECTION,
                uid,
                MESSAGES_SUBCOLLECTION,
                message.id
            );

            let response = self
                .build_request(reqwest::Method::DELETE, &url)
                .await?
                .send()
                .await?;

            if !response.status().is_success() && response.status() != reqwest::StatusCode::NOT_FOUND {
                tracing::warn!("Failed to delete message {}: {:?}", message.id, response.status());
            }
        }

        // Also delete the chat session
        if let Some(session) = self.get_chat_session(uid, app_id).await? {
            let url = format!(
                "{}/{}/{}/{}/{}",
                self.base_url(),
                USERS_COLLECTION,
                uid,
                CHAT_SESSIONS_SUBCOLLECTION,
                session.id
            );

            let _ = self
                .build_request(reqwest::Method::DELETE, &url)
                .await?
                .send()
                .await;
        }

        tracing::info!("Deleted {} messages for user {} (app_id: {:?})", count, uid, app_id);
        Ok(count)
    }

    /// Parse Firestore document to ChatSession
    fn parse_chat_session(
        &self,
        doc: &Value,
    ) -> Result<ChatSession, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        Ok(ChatSession {
            id,
            created_at: self.parse_timestamp_optional(fields, "created_at").unwrap_or_else(Utc::now),
            message_ids: self.parse_string_array(fields, "message_ids"),
            app_id: self.parse_string(fields, "app_id"),
        })
    }

    /// Parse Firestore document to Message
    fn parse_message(
        &self,
        doc: &Value,
    ) -> Result<Message, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        let sender_str = self.parse_string(fields, "sender").unwrap_or_else(|| "human".to_string());
        let sender = match sender_str.as_str() {
            "ai" => MessageSender::Ai,
            _ => MessageSender::Human,
        };

        let type_str = self.parse_string(fields, "type").unwrap_or_else(|| "text".to_string());
        let message_type = match type_str.as_str() {
            "day_summary" => MessageType::DaySummary,
            _ => MessageType::Text,
        };

        Ok(Message {
            id,
            text: self.parse_string(fields, "text").unwrap_or_default(),
            created_at: self.parse_timestamp_optional(fields, "created_at").unwrap_or_else(Utc::now),
            sender,
            app_id: self.parse_string(fields, "app_id"),
            message_type,
            memories_id: self.parse_string_array(fields, "memories_id"),
            chat_session_id: self.parse_string(fields, "chat_session_id"),
        })
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

        // Parse apps_results
        let apps_results = self.parse_apps_results(fields);

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
            apps_results,
        })
    }

    /// Parse apps_results array from Firestore fields
    fn parse_apps_results(&self, fields: &Value) -> Vec<crate::models::AppResult> {
        let array = match fields.get("apps_results")
            .and_then(|a| a.get("arrayValue"))
            .and_then(|a| a.get("values"))
            .and_then(|a| a.as_array())
        {
            Some(arr) => arr,
            None => return vec![],
        };

        array.iter().filter_map(|item| {
            let map_fields = item.get("mapValue")?.get("fields")?;
            let app_id = self.parse_string(map_fields, "app_id");
            let content = self.parse_string(map_fields, "content").unwrap_or_default();
            Some(crate::models::AppResult { app_id, content })
        }).collect()
    }

    /// Parse Firestore document to ActionItemDB
    fn parse_action_item(
        &self,
        doc: &Value,
    ) -> Result<ActionItemDB, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        Ok(ActionItemDB {
            id,
            description: self.parse_string(fields, "description").unwrap_or_default(),
            completed: self.parse_bool(fields, "completed").unwrap_or(false),
            created_at: self.parse_timestamp_optional(fields, "created_at").unwrap_or_else(Utc::now),
            updated_at: self.parse_timestamp_optional(fields, "updated_at"),
            due_at: self.parse_timestamp_optional(fields, "due_at"),
            completed_at: self.parse_timestamp_optional(fields, "completed_at"),
            conversation_id: self.parse_string(fields, "conversation_id"),
            source: self.parse_string(fields, "source"),
            priority: self.parse_string(fields, "priority"),
            metadata: self.parse_string(fields, "metadata"),
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

    // =========================================================================
    // USER SETTINGS
    // =========================================================================

    /// Get user document fields
    async fn get_user_document(
        &self,
        uid: &str,
    ) -> Result<Value, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!("{}/{}/{}", self.base_url(), USERS_COLLECTION, uid);

        let response = self
            .build_request(reqwest::Method::GET, &url)
            .await?
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Failed to get user document: {}", error_text).into());
        }

        let doc: Value = response.json().await?;
        Ok(doc)
    }

    /// Update user document fields (partial update)
    async fn update_user_fields(
        &self,
        uid: &str,
        fields: Value,
        update_mask: &[&str],
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let mask_params = update_mask
            .iter()
            .map(|f| format!("updateMask.fieldPaths={}", f))
            .collect::<Vec<_>>()
            .join("&");

        let url = format!(
            "{}/{}/{}?{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            mask_params
        );

        let doc = json!({ "fields": fields });

        let response = self
            .build_request(reqwest::Method::PATCH, &url)
            .await?
            .json(&doc)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Failed to update user fields: {}", error_text).into());
        }

        Ok(())
    }

    /// Get daily summary settings for a user
    pub async fn get_daily_summary_settings(
        &self,
        uid: &str,
    ) -> Result<DailySummarySettings, Box<dyn std::error::Error + Send + Sync>> {
        let doc = self.get_user_document(uid).await?;
        let empty = json!({});
        let fields = doc.get("fields").unwrap_or(&empty);

        Ok(DailySummarySettings {
            enabled: self.parse_bool(fields, "daily_summary_enabled").unwrap_or(true),
            hour: self.parse_int(fields, "daily_summary_hour_local").unwrap_or(22),
        })
    }

    /// Update daily summary settings for a user
    pub async fn update_daily_summary_settings(
        &self,
        uid: &str,
        enabled: Option<bool>,
        hour: Option<i32>,
    ) -> Result<DailySummarySettings, Box<dyn std::error::Error + Send + Sync>> {
        // Get current settings
        let current = self.get_daily_summary_settings(uid).await?;

        let new_enabled = enabled.unwrap_or(current.enabled);
        let new_hour = hour.unwrap_or(current.hour);

        let fields = json!({
            "daily_summary_enabled": {"booleanValue": new_enabled},
            "daily_summary_hour_local": {"integerValue": new_hour.to_string()}
        });

        self.update_user_fields(uid, fields, &["daily_summary_enabled", "daily_summary_hour_local"])
            .await?;

        Ok(DailySummarySettings {
            enabled: new_enabled,
            hour: new_hour,
        })
    }

    /// Get transcription preferences for a user
    pub async fn get_transcription_preferences(
        &self,
        uid: &str,
    ) -> Result<TranscriptionPreferences, Box<dyn std::error::Error + Send + Sync>> {
        let doc = self.get_user_document(uid).await?;
        let empty = json!({});
        let fields = doc.get("fields").unwrap_or(&empty);

        // Parse nested transcription_preferences object
        let prefs = fields
            .get("transcription_preferences")
            .and_then(|p| p.get("mapValue"))
            .and_then(|m| m.get("fields"));

        if let Some(pref_fields) = prefs {
            Ok(TranscriptionPreferences {
                single_language_mode: self.parse_bool(pref_fields, "single_language_mode").unwrap_or(false),
                vocabulary: self.parse_string_array(pref_fields, "vocabulary"),
            })
        } else {
            Ok(TranscriptionPreferences::default())
        }
    }

    /// Update transcription preferences for a user
    pub async fn update_transcription_preferences(
        &self,
        uid: &str,
        single_language_mode: Option<bool>,
        vocabulary: Option<Vec<String>>,
    ) -> Result<TranscriptionPreferences, Box<dyn std::error::Error + Send + Sync>> {
        // Get current settings
        let current = self.get_transcription_preferences(uid).await?;

        let new_single_language_mode = single_language_mode.unwrap_or(current.single_language_mode);
        let new_vocabulary = vocabulary.unwrap_or(current.vocabulary);

        let vocab_values: Vec<Value> = new_vocabulary
            .iter()
            .map(|v| json!({"stringValue": v}))
            .collect();

        let fields = json!({
            "transcription_preferences": {
                "mapValue": {
                    "fields": {
                        "single_language_mode": {"booleanValue": new_single_language_mode},
                        "vocabulary": {
                            "arrayValue": {
                                "values": vocab_values
                            }
                        }
                    }
                }
            }
        });

        self.update_user_fields(uid, fields, &["transcription_preferences"])
            .await?;

        Ok(TranscriptionPreferences {
            single_language_mode: new_single_language_mode,
            vocabulary: new_vocabulary,
        })
    }

    /// Get user language preference
    pub async fn get_user_language(
        &self,
        uid: &str,
    ) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        let doc = self.get_user_document(uid).await?;
        let empty = json!({});
        let fields = doc.get("fields").unwrap_or(&empty);

        Ok(self.parse_string(fields, "language").unwrap_or_else(|| "en".to_string()))
    }

    /// Update user language preference
    pub async fn update_user_language(
        &self,
        uid: &str,
        language: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let fields = json!({
            "language": {"stringValue": language}
        });

        self.update_user_fields(uid, fields, &["language"]).await
    }

    /// Get recording permission for a user
    pub async fn get_recording_permission(
        &self,
        uid: &str,
    ) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
        let doc = self.get_user_document(uid).await?;
        let empty = json!({});
        let fields = doc.get("fields").unwrap_or(&empty);

        Ok(self.parse_bool(fields, "store_recording_permission").unwrap_or(false))
    }

    /// Set recording permission for a user
    pub async fn set_recording_permission(
        &self,
        uid: &str,
        enabled: bool,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let fields = json!({
            "store_recording_permission": {"booleanValue": enabled}
        });

        self.update_user_fields(uid, fields, &["store_recording_permission"]).await
    }

    /// Get private cloud sync setting for a user
    pub async fn get_private_cloud_sync(
        &self,
        uid: &str,
    ) -> Result<bool, Box<dyn std::error::Error + Send + Sync>> {
        let doc = self.get_user_document(uid).await?;
        let empty = json!({});
        let fields = doc.get("fields").unwrap_or(&empty);

        // Default to true if not set
        Ok(self.parse_bool(fields, "private_cloud_sync_enabled").unwrap_or(true))
    }

    /// Set private cloud sync setting for a user
    pub async fn set_private_cloud_sync(
        &self,
        uid: &str,
        enabled: bool,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let fields = json!({
            "private_cloud_sync_enabled": {"booleanValue": enabled}
        });

        self.update_user_fields(uid, fields, &["private_cloud_sync_enabled"]).await
    }

    /// Get notification settings for a user
    pub async fn get_notification_settings(
        &self,
        uid: &str,
    ) -> Result<NotificationSettings, Box<dyn std::error::Error + Send + Sync>> {
        let doc = self.get_user_document(uid).await?;
        let empty = json!({});
        let fields = doc.get("fields").unwrap_or(&empty);

        Ok(NotificationSettings {
            enabled: self.parse_bool(fields, "notifications_enabled").unwrap_or(true),
            frequency: self.parse_int(fields, "notification_frequency").unwrap_or(3),
        })
    }

    /// Update notification settings for a user
    pub async fn update_notification_settings(
        &self,
        uid: &str,
        enabled: Option<bool>,
        frequency: Option<i32>,
    ) -> Result<NotificationSettings, Box<dyn std::error::Error + Send + Sync>> {
        // Get current settings
        let current = self.get_notification_settings(uid).await?;

        let new_enabled = enabled.unwrap_or(current.enabled);
        let new_frequency = frequency.unwrap_or(current.frequency);

        let fields = json!({
            "notifications_enabled": {"booleanValue": new_enabled},
            "notification_frequency": {"integerValue": new_frequency.to_string()}
        });

        self.update_user_fields(uid, fields, &["notifications_enabled", "notification_frequency"])
            .await?;

        Ok(NotificationSettings {
            enabled: new_enabled,
            frequency: new_frequency,
        })
    }

    /// Get user profile
    pub async fn get_user_profile(
        &self,
        uid: &str,
    ) -> Result<UserProfile, Box<dyn std::error::Error + Send + Sync>> {
        let doc = self.get_user_document(uid).await?;
        let empty = json!({});
        let fields = doc.get("fields").unwrap_or(&empty);

        Ok(UserProfile {
            uid: uid.to_string(),
            email: self.parse_string(fields, "email"),
            name: self.parse_string(fields, "name"),
            time_zone: self.parse_string(fields, "time_zone"),
            created_at: self.parse_timestamp_optional(fields, "created_at")
                .map(|dt| dt.to_rfc3339()),
        })
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
