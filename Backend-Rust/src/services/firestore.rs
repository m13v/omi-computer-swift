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
    ActionItem, ActionItemDB, AdviceCategory, AdviceDB, App, AppReview, AppSummary, Category,
    Conversation, DailySummarySettings, DistractionEntry, EmailAttachment, FocusSessionDB,
    FocusStats, FocusStatus, InboundEmailDB, Memory, MemoryCategory, MemoryDB,
    NotificationSettings, Structured, TranscriptSegment, TranscriptionPreferences, UserProfile,
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
pub const FOCUS_SESSIONS_SUBCOLLECTION: &str = "focus_sessions";
pub const ADVICE_SUBCOLLECTION: &str = "advice";
pub const EMAILS_COLLECTION: &str = "emails";

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
        // Use service account credentials first (has full permissions)
        if let Some(creds) = &self.credentials {
            let token = self.get_token_from_service_account(creds).await?;
            tracing::info!("Got access token from service account");
            return Ok(token);
        }

        // Fall back to metadata server (for GKE/Cloud Run without credentials file)
        if let Ok(token) = self.try_metadata_server().await {
            tracing::info!("Got access token from GCP metadata server");
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

    /// Get count of conversations for a user using Firestore aggregation query
    pub async fn get_conversations_count(
        &self,
        uid: &str,
        include_discarded: bool,
        statuses: &[String],
    ) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!(
            "{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid
        );

        // Build filters (same as get_conversations)
        let mut filters: Vec<Value> = Vec::new();

        if !include_discarded {
            filters.push(json!({
                "fieldFilter": {
                    "field": {"fieldPath": "discarded"},
                    "op": "EQUAL",
                    "value": {"booleanValue": false}
                }
            }));
        }

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

        let mut structured_query = json!({
            "from": [{"collectionId": CONVERSATIONS_SUBCOLLECTION}]
        });

        if let Some(where_filter) = where_clause {
            structured_query["where"] = where_filter;
        }

        let query = json!({
            "structuredAggregationQuery": {
                "structuredQuery": structured_query,
                "aggregations": [{
                    "alias": "count",
                    "count": {}
                }]
            }
        });

        let response = self
            .build_request(reqwest::Method::POST, &format!("{}:runAggregationQuery", parent))
            .await?
            .json(&query)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            tracing::error!("Firestore aggregation query error: {}", error_text);
            return Err(format!("Firestore aggregation query failed: {}", error_text).into());
        }

        let results: Vec<Value> = response.json().await?;

        // Parse the count from aggregation result
        // Response format: [{"result": {"aggregateFields": {"count": {"integerValue": "123"}}}}]
        let count = results
            .first()
            .and_then(|r| r.get("result"))
            .and_then(|r| r.get("aggregateFields"))
            .and_then(|f| f.get("count"))
            .and_then(|c| c.get("integerValue"))
            .and_then(|v| v.as_str())
            .and_then(|s| s.parse::<i64>().ok())
            .unwrap_or(0);

        tracing::info!("Conversations count for user {}: {}", uid, count);
        Ok(count)
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
    /// Enriches memories with source from linked conversations
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
        let mut memories: Vec<MemoryDB> = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_memory(d).ok())
            })
            // Filter out rejected memories
            .filter(|m| m.user_review != Some(false))
            .collect();

        // Enrich memories with source from linked conversations
        self.enrich_memories_with_source(uid, &mut memories).await;

        Ok(memories)
    }

    /// Batch fetch conversations and populate source field on memories
    async fn enrich_memories_with_source(&self, uid: &str, memories: &mut [MemoryDB]) {
        use std::collections::{HashMap, HashSet};

        // Collect unique conversation IDs
        let conversation_ids: HashSet<&str> = memories
            .iter()
            .filter_map(|m| m.conversation_id.as_deref())
            .collect();

        if conversation_ids.is_empty() {
            return;
        }

        // Fetch conversations in parallel (limit to avoid too many concurrent requests)
        let mut source_map: HashMap<String, String> = HashMap::new();

        // Batch fetch - fetch up to 10 at a time
        let ids: Vec<&str> = conversation_ids.into_iter().collect();
        for chunk in ids.chunks(10) {
            let futures: Vec<_> = chunk
                .iter()
                .map(|id| self.get_conversation(uid, id))
                .collect();

            let results = futures::future::join_all(futures).await;

            for (id, result) in chunk.iter().zip(results) {
                if let Ok(Some(conv)) = result {
                    let source_str = format!("{:?}", conv.source).to_lowercase();
                    source_map.insert(id.to_string(), source_str);
                }
            }
        }

        // Populate source field on memories
        for memory in memories.iter_mut() {
            if let Some(conv_id) = &memory.conversation_id {
                memory.source = source_map.get(conv_id).cloned();
            }
        }
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

        // Note: We don't use orderBy in the query because it would require a composite index
        // Instead, we fetch all matching apps and sort in memory (matching Python backend behavior)
        let mut structured_query = json!({
            "from": [{"collectionId": APPS_COLLECTION}]
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

        // Sort by installs descending (in memory, to avoid needing composite index)
        apps.sort_by(|a, b| b.installs.cmp(&a.installs));

        // Apply pagination
        let start = offset.min(apps.len());
        let end = (offset + limit).min(apps.len());
        Ok(apps[start..end].to_vec())
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

    /// Get user's enabled apps as summaries
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

    /// Get user's enabled apps with full App details (for integration triggers)
    pub async fn get_enabled_apps_full(
        &self,
        uid: &str,
    ) -> Result<Vec<App>, Box<dyn std::error::Error + Send + Sync>> {
        let enabled_ids = self.get_enabled_app_ids(uid).await?;

        let mut apps = Vec::new();
        for app_id in enabled_ids {
            if let Ok(Some(mut app)) = self.get_app(uid, &app_id).await {
                app.enabled = true;
                apps.push(app);
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
            source: None, // Enriched later from linked conversation
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
    /// Handles both plain arrays and zlib-compressed bytes (from OMI device).
    /// Encrypted segments (enhanced protection) return empty vec - not yet supported.
    fn parse_transcript_segments(
        &self,
        fields: &Value,
    ) -> Result<Vec<TranscriptSegment>, Box<dyn std::error::Error + Send + Sync>> {
        let transcript_field = fields.get("transcript_segments");

        // Check if transcript is a string (encrypted) - not yet supported
        if let Some(_string_val) = transcript_field.and_then(|t| t.get("stringValue")) {
            tracing::debug!("Transcript segments are encrypted (string format), returning empty");
            return Ok(vec![]);
        }

        // Check if transcript is bytes (zlib compressed) - decompress it
        if let Some(bytes_val) = transcript_field.and_then(|t| t.get("bytesValue")) {
            if let Some(b64_str) = bytes_val.as_str() {
                match self.decompress_transcript_segments(b64_str) {
                    Ok(segments) => {
                        tracing::debug!("Decompressed {} transcript segments", segments.len());
                        return Ok(segments);
                    }
                    Err(e) => {
                        tracing::warn!("Failed to decompress transcript segments: {}", e);
                        return Ok(vec![]);
                    }
                }
            }
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

    /// Decompress zlib-compressed transcript segments from base64-encoded bytes
    fn decompress_transcript_segments(
        &self,
        b64_str: &str,
    ) -> Result<Vec<TranscriptSegment>, Box<dyn std::error::Error + Send + Sync>> {
        use flate2::read::ZlibDecoder;
        use std::io::Read;

        // Decode base64 to bytes
        let compressed_bytes = base64::Engine::decode(
            &base64::engine::general_purpose::STANDARD,
            b64_str,
        )?;

        // Decompress with zlib
        let mut decoder = ZlibDecoder::new(&compressed_bytes[..]);
        let mut decompressed = String::new();
        decoder.read_to_string(&mut decompressed)?;

        // Parse JSON array of segments
        let segments: Vec<serde_json::Value> = serde_json::from_str(&decompressed)?;

        // Convert to TranscriptSegment
        Ok(segments
            .iter()
            .filter_map(|seg| {
                Some(TranscriptSegment {
                    text: seg.get("text")?.as_str()?.to_string(),
                    speaker: seg
                        .get("speaker")
                        .and_then(|s| s.as_str())
                        .unwrap_or("SPEAKER_00")
                        .to_string(),
                    speaker_id: seg
                        .get("speaker_id")
                        .and_then(|s| s.as_i64())
                        .unwrap_or(0) as i32,
                    is_user: seg
                        .get("is_user")
                        .and_then(|s| s.as_bool())
                        .unwrap_or(false),
                    start: seg
                        .get("start")
                        .and_then(|s| s.as_f64())
                        .unwrap_or(0.0),
                    end: seg
                        .get("end")
                        .and_then(|s| s.as_f64())
                        .unwrap_or(0.0),
                })
            })
            .collect())
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

    // =========================================================================
    // FOCUS SESSIONS
    // =========================================================================

    /// Create a focus session
    /// Path: users/{uid}/focus_sessions/{session_id}
    pub async fn create_focus_session(
        &self,
        uid: &str,
        status: &FocusStatus,
        app_or_site: &str,
        description: &str,
        message: Option<&str>,
    ) -> Result<FocusSessionDB, Box<dyn std::error::Error + Send + Sync>> {
        let session_id = uuid::Uuid::new_v4().to_string();
        let now = Utc::now();

        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            FOCUS_SESSIONS_SUBCOLLECTION,
            session_id
        );

        let status_str = match status {
            FocusStatus::Focused => "focused",
            FocusStatus::Distracted => "distracted",
        };

        let mut fields = json!({
            "status": {"stringValue": status_str},
            "app_or_site": {"stringValue": app_or_site},
            "description": {"stringValue": description},
            "created_at": {"timestampValue": now.to_rfc3339()}
        });

        if let Some(msg) = message {
            fields["message"] = json!({"stringValue": msg});
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

        tracing::info!(
            "Created focus session {} for user {} with status={}",
            session_id,
            uid,
            status_str
        );

        Ok(FocusSessionDB {
            id: session_id,
            status: status.clone(),
            app_or_site: app_or_site.to_string(),
            description: description.to_string(),
            message: message.map(|s| s.to_string()),
            created_at: now,
            duration_seconds: None,
        })
    }

    /// Get focus sessions for a user
    /// Path: users/{uid}/focus_sessions
    pub async fn get_focus_sessions(
        &self,
        uid: &str,
        limit: usize,
        offset: usize,
        date_filter: Option<&str>,
    ) -> Result<Vec<FocusSessionDB>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!("{}/{}/{}", self.base_url(), USERS_COLLECTION, uid);

        // Build filters
        let mut filters: Vec<Value> = Vec::new();

        // If date filter provided, filter by date range
        if let Some(date) = date_filter {
            // Parse date and create start/end timestamps
            if let Ok(parsed_date) = chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d") {
                let start = parsed_date
                    .and_hms_opt(0, 0, 0)
                    .unwrap()
                    .and_utc();
                let end = parsed_date
                    .and_hms_opt(23, 59, 59)
                    .unwrap()
                    .and_utc();

                filters.push(json!({
                    "fieldFilter": {
                        "field": {"fieldPath": "created_at"},
                        "op": "GREATER_THAN_OR_EQUAL",
                        "value": {"timestampValue": start.to_rfc3339()}
                    }
                }));
                filters.push(json!({
                    "fieldFilter": {
                        "field": {"fieldPath": "created_at"},
                        "op": "LESS_THAN_OR_EQUAL",
                        "value": {"timestampValue": end.to_rfc3339()}
                    }
                }));
            }
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
            "from": [{"collectionId": FOCUS_SESSIONS_SUBCOLLECTION}],
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
        let sessions = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_focus_session(d).ok())
            })
            .collect();

        Ok(sessions)
    }

    /// Delete a focus session
    pub async fn delete_focus_session(
        &self,
        uid: &str,
        session_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            FOCUS_SESSIONS_SUBCOLLECTION,
            session_id
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

        tracing::info!("Deleted focus session {} for user {}", session_id, uid);
        Ok(())
    }

    /// Get focus statistics for a date
    pub async fn get_focus_stats(
        &self,
        uid: &str,
        date: &str,
    ) -> Result<FocusStats, Box<dyn std::error::Error + Send + Sync>> {
        // Get all sessions for the date
        let sessions = self.get_focus_sessions(uid, 1000, 0, Some(date)).await?;

        let mut focused_count: i64 = 0;
        let mut distracted_count: i64 = 0;
        let mut distraction_map: std::collections::HashMap<String, (i64, i64)> =
            std::collections::HashMap::new();

        for session in &sessions {
            match session.status {
                FocusStatus::Focused => focused_count += 1,
                FocusStatus::Distracted => {
                    distracted_count += 1;
                    let entry = distraction_map
                        .entry(session.app_or_site.clone())
                        .or_insert((0, 0));
                    entry.0 += session.duration_seconds.unwrap_or(60); // Default 60s per session
                    entry.1 += 1;
                }
            }
        }

        // Build top distractions
        let mut top_distractions: Vec<DistractionEntry> = distraction_map
            .into_iter()
            .map(|(app, (secs, count))| DistractionEntry {
                app_or_site: app,
                total_seconds: secs,
                count,
            })
            .collect();

        // Sort by total time descending
        top_distractions.sort_by(|a, b| b.total_seconds.cmp(&a.total_seconds));

        // Take top 5
        top_distractions.truncate(5);

        // Estimate minutes (each session ~1 minute if no duration)
        let focused_minutes = focused_count;
        let distracted_minutes = distracted_count;

        Ok(FocusStats {
            date: date.to_string(),
            focused_minutes,
            distracted_minutes,
            session_count: sessions.len() as i64,
            focused_count,
            distracted_count,
            top_distractions,
        })
    }

    /// Parse a focus session from Firestore document
    fn parse_focus_session(
        &self,
        doc: &Value,
    ) -> Result<FocusSessionDB, Box<dyn std::error::Error + Send + Sync>> {
        let name = doc
            .get("name")
            .and_then(|n| n.as_str())
            .ok_or("Missing document name")?;

        let id = name.split('/').last().unwrap_or("unknown").to_string();

        let fields = doc.get("fields").ok_or("Missing fields")?;

        let status_str = self.parse_string(fields, "status").unwrap_or_default();
        let status = match status_str.as_str() {
            "focused" => FocusStatus::Focused,
            _ => FocusStatus::Distracted,
        };

        Ok(FocusSessionDB {
            id,
            status,
            app_or_site: self.parse_string(fields, "app_or_site").unwrap_or_default(),
            description: self.parse_string(fields, "description").unwrap_or_default(),
            message: self.parse_string(fields, "message"),
            created_at: self
                .parse_timestamp_optional(fields, "created_at")
                .unwrap_or_else(Utc::now),
            duration_seconds: self.parse_int(fields, "duration_seconds").map(|v| v as i64),
        })
    }

    // =========================================================================
    // ADVICE
    // =========================================================================

    /// Create a new advice entry
    /// Path: users/{uid}/advice/{advice_id}
    pub async fn create_advice(
        &self,
        uid: &str,
        content: &str,
        category: Option<AdviceCategory>,
        reasoning: Option<&str>,
        source_app: Option<&str>,
        confidence: Option<f64>,
        context_summary: Option<&str>,
        current_activity: Option<&str>,
    ) -> Result<AdviceDB, Box<dyn std::error::Error + Send + Sync>> {
        let advice_id = uuid::Uuid::new_v4().to_string();
        let now = Utc::now();

        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            ADVICE_SUBCOLLECTION,
            advice_id
        );

        let category_str = match category.unwrap_or(AdviceCategory::Other) {
            AdviceCategory::Productivity => "productivity",
            AdviceCategory::Health => "health",
            AdviceCategory::Communication => "communication",
            AdviceCategory::Learning => "learning",
            AdviceCategory::Other => "other",
        };

        let mut fields = json!({
            "content": {"stringValue": content},
            "category": {"stringValue": category_str},
            "confidence": {"doubleValue": confidence.unwrap_or(0.5)},
            "is_read": {"booleanValue": false},
            "is_dismissed": {"booleanValue": false},
            "created_at": {"timestampValue": now.to_rfc3339()}
        });

        if let Some(r) = reasoning {
            fields["reasoning"] = json!({"stringValue": r});
        }
        if let Some(app) = source_app {
            fields["source_app"] = json!({"stringValue": app});
        }
        if let Some(summary) = context_summary {
            fields["context_summary"] = json!({"stringValue": summary});
        }
        if let Some(activity) = current_activity {
            fields["current_activity"] = json!({"stringValue": activity});
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

        let created_doc: Value = response.json().await?;
        let advice = self.parse_advice(&created_doc)?;

        tracing::info!("Created advice {} for user {}", advice_id, uid);
        Ok(advice)
    }

    /// Get advice for a user
    /// Path: users/{uid}/advice
    pub async fn get_advice(
        &self,
        uid: &str,
        limit: usize,
        offset: usize,
        category: Option<&str>,
        include_dismissed: bool,
    ) -> Result<Vec<AdviceDB>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = format!("{}/{}/{}", self.base_url(), USERS_COLLECTION, uid);

        // Build filters
        let mut filters: Vec<Value> = Vec::new();

        // Filter out dismissed unless requested
        if !include_dismissed {
            filters.push(json!({
                "fieldFilter": {
                    "field": {"fieldPath": "is_dismissed"},
                    "op": "EQUAL",
                    "value": {"booleanValue": false}
                }
            }));
        }

        // Filter by category if specified
        if let Some(cat) = category {
            filters.push(json!({
                "fieldFilter": {
                    "field": {"fieldPath": "category"},
                    "op": "EQUAL",
                    "value": {"stringValue": cat}
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
            "from": [{"collectionId": ADVICE_SUBCOLLECTION}],
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
        let advice_list = results
            .into_iter()
            .filter_map(|doc| {
                doc.get("document")
                    .and_then(|d| self.parse_advice(d).ok())
            })
            .collect();

        Ok(advice_list)
    }

    /// Update advice (mark as read/dismissed)
    pub async fn update_advice(
        &self,
        uid: &str,
        advice_id: &str,
        is_read: Option<bool>,
        is_dismissed: Option<bool>,
    ) -> Result<AdviceDB, Box<dyn std::error::Error + Send + Sync>> {
        let mut field_paths: Vec<&str> = vec!["updated_at"];
        let mut fields = json!({
            "updated_at": {"timestampValue": Utc::now().to_rfc3339()}
        });

        if let Some(read) = is_read {
            field_paths.push("is_read");
            fields["is_read"] = json!({"booleanValue": read});
        }

        if let Some(dismissed) = is_dismissed {
            field_paths.push("is_dismissed");
            fields["is_dismissed"] = json!({"booleanValue": dismissed});
        }

        let update_mask = field_paths
            .iter()
            .map(|f| format!("updateMask.fieldPaths={}", f))
            .collect::<Vec<_>>()
            .join("&");

        let url = format!(
            "{}/{}/{}/{}/{}?{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            ADVICE_SUBCOLLECTION,
            advice_id,
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

        let updated_doc: Value = response.json().await?;
        let advice = self.parse_advice(&updated_doc)?;

        tracing::info!("Updated advice {} for user {}", advice_id, uid);
        Ok(advice)
    }

    /// Delete advice permanently
    pub async fn delete_advice(
        &self,
        uid: &str,
        advice_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}/{}/{}",
            self.base_url(),
            USERS_COLLECTION,
            uid,
            ADVICE_SUBCOLLECTION,
            advice_id
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

        tracing::info!("Deleted advice {} for user {}", advice_id, uid);
        Ok(())
    }

    /// Mark all advice as read for a user
    pub async fn mark_all_advice_read(
        &self,
        uid: &str,
    ) -> Result<usize, Box<dyn std::error::Error + Send + Sync>> {
        // Get all unread advice
        let advice_list = self.get_advice(uid, 1000, 0, None, false).await?;
        let unread: Vec<_> = advice_list.iter().filter(|a| !a.is_read).collect();
        let count = unread.len();

        // Update each one
        for advice in unread {
            let _ = self.update_advice(uid, &advice.id, Some(true), None).await;
        }

        Ok(count)
    }

    /// Parse Firestore document to AdviceDB
    fn parse_advice(
        &self,
        doc: &Value,
    ) -> Result<AdviceDB, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields")?;
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        let category_str = self.parse_string(fields, "category").unwrap_or_else(|| "other".to_string());
        let category = match category_str.as_str() {
            "productivity" => AdviceCategory::Productivity,
            "health" => AdviceCategory::Health,
            "communication" => AdviceCategory::Communication,
            "learning" => AdviceCategory::Learning,
            _ => AdviceCategory::Other,
        };

        Ok(AdviceDB {
            id,
            content: self.parse_string(fields, "content").unwrap_or_default(),
            category,
            reasoning: self.parse_string(fields, "reasoning"),
            source_app: self.parse_string(fields, "source_app"),
            confidence: self.parse_float(fields, "confidence").unwrap_or(0.5),
            context_summary: self.parse_string(fields, "context_summary"),
            current_activity: self.parse_string(fields, "current_activity"),
            created_at: self.parse_timestamp_optional(fields, "created_at").unwrap_or_else(Utc::now),
            updated_at: self.parse_timestamp_optional(fields, "updated_at"),
            is_read: self.parse_bool(fields, "is_read").unwrap_or(false),
            is_dismissed: self.parse_bool(fields, "is_dismissed").unwrap_or(false),
        })
    }

    // =========================================================================
    // Desktop Releases (for Sparkle auto-update)
    // =========================================================================

    /// Get desktop releases for auto-update appcast
    /// Fetches from desktop_releases collection
    pub async fn get_desktop_releases(
        &self,
    ) -> Result<Vec<crate::routes::updates::ReleaseInfo>, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/desktop_releases",
            self.base_url()
        );

        let response = self
            .build_request(reqwest::Method::GET, &url)
            .await?
            .send()
            .await?;

        if !response.status().is_success() {
            // If collection doesn't exist, return empty list
            if response.status() == reqwest::StatusCode::NOT_FOUND {
                return Ok(vec![]);
            }
            let error_text = response.text().await?;
            return Err(format!("Firestore error: {}", error_text).into());
        }

        let data: Value = response.json().await?;
        let mut releases = Vec::new();

        if let Some(documents) = data.get("documents").and_then(|d| d.as_array()) {
            for doc in documents {
                if let Ok(release) = self.parse_release(doc) {
                    releases.push(release);
                }
            }
        }

        // Sort by build number descending (newest first)
        releases.sort_by(|a, b| b.build_number.cmp(&a.build_number));

        Ok(releases)
    }

    /// Parse Firestore document to ReleaseInfo
    fn parse_release(
        &self,
        doc: &Value,
    ) -> Result<crate::routes::updates::ReleaseInfo, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc.get("fields").ok_or("Missing fields")?;

        let changelog = if let Some(arr) = fields.get("changelog").and_then(|c| c.get("arrayValue")).and_then(|a| a.get("values")).and_then(|v| v.as_array()) {
            arr.iter()
                .filter_map(|v| v.get("stringValue").and_then(|s| s.as_str()))
                .map(|s| s.to_string())
                .collect()
        } else {
            vec![]
        };

        Ok(crate::routes::updates::ReleaseInfo {
            version: self.parse_string(fields, "version").unwrap_or_default(),
            build_number: self.parse_int(fields, "build_number").unwrap_or(0) as u32,
            download_url: self.parse_string(fields, "download_url").unwrap_or_default(),
            ed_signature: self.parse_string(fields, "ed_signature").unwrap_or_default(),
            published_at: self.parse_string(fields, "published_at").unwrap_or_default(),
            changelog,
            is_live: self.parse_bool(fields, "is_live").unwrap_or(false),
            is_critical: self.parse_bool(fields, "is_critical").unwrap_or(false),
        })
    }

    /// Create a new desktop release in Firestore
    pub async fn create_desktop_release(
        &self,
        release: &crate::routes::updates::ReleaseInfo,
    ) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
        let doc_id = format!("v{}+{}", release.version, release.build_number);

        let url = format!(
            "{}/desktop_releases/{}",
            self.base_url(),
            doc_id
        );

        // Build changelog array
        let changelog_values: Vec<Value> = release.changelog
            .iter()
            .map(|s| json!({"stringValue": s}))
            .collect();

        let doc = json!({
            "fields": {
                "version": {"stringValue": release.version},
                "build_number": {"integerValue": release.build_number.to_string()},
                "download_url": {"stringValue": release.download_url},
                "ed_signature": {"stringValue": release.ed_signature},
                "published_at": {"stringValue": release.published_at},
                "changelog": {"arrayValue": {"values": changelog_values}},
                "is_live": {"booleanValue": release.is_live},
                "is_critical": {"booleanValue": release.is_critical}
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

        tracing::info!("Created desktop release: {}", doc_id);
        Ok(doc_id)
    }

    // =========================================================================
    // EMAILS - Inbound email storage
    // =========================================================================

    /// Create/store an inbound email
    pub async fn create_email(
        &self,
        email: &InboundEmailDB,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!("{}/{}/{}", self.base_url(), EMAILS_COLLECTION, email.id);

        // Build attachments array
        let attachments_value: Vec<Value> = email
            .attachments
            .iter()
            .map(|att| {
                json!({
                    "mapValue": {
                        "fields": {
                            "filename": {"stringValue": &att.filename},
                            "content_type": {"stringValue": &att.content_type},
                            "size": {"integerValue": att.size.to_string()}
                        }
                    }
                })
            })
            .collect();

        // Build to array
        let to_value: Vec<Value> = email
            .to
            .iter()
            .map(|addr| json!({"stringValue": addr}))
            .collect();

        let mut fields = json!({
            "from": {"stringValue": &email.from_email},
            "to": {"arrayValue": {"values": to_value}},
            "subject": {"stringValue": &email.subject},
            "received_at": {"timestampValue": email.received_at.to_rfc3339()},
            "read": {"booleanValue": email.read},
            "attachments": {"arrayValue": {"values": attachments_value}}
        });

        if let Some(text) = &email.text {
            fields["text"] = json!({"stringValue": text});
        }

        if let Some(html) = &email.html {
            fields["html"] = json!({"stringValue": html});
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
            return Err(format!("Firestore create email error: {}", error_text).into());
        }

        Ok(())
    }

    /// List emails with pagination (ordered by received_at descending)
    pub async fn list_emails(
        &self,
        limit: usize,
        offset: usize,
    ) -> Result<Vec<InboundEmailDB>, Box<dyn std::error::Error + Send + Sync>> {
        let parent = self.base_url();

        let query = json!({
            "structuredQuery": {
                "from": [{"collectionId": EMAILS_COLLECTION}],
                "orderBy": [{
                    "field": {"fieldPath": "received_at"},
                    "direction": "DESCENDING"
                }],
                "limit": limit,
                "offset": offset
            }
        });

        let url = format!("{}:runQuery", parent);

        let response = self
            .build_request(reqwest::Method::POST, &url)
            .await?
            .json(&query)
            .send()
            .await?;

        if !response.status().is_success() {
            let error_text = response.text().await?;
            return Err(format!("Firestore list emails error: {}", error_text).into());
        }

        let results: Vec<Value> = response.json().await?;
        let mut emails = Vec::new();

        for result in results {
            if let Some(doc) = result.get("document") {
                if let Ok(email) = self.parse_email(doc) {
                    emails.push(email);
                }
            }
        }

        Ok(emails)
    }

    /// Get a single email by ID
    pub async fn get_email(
        &self,
        email_id: &str,
    ) -> Result<Option<InboundEmailDB>, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!("{}/{}/{}", self.base_url(), EMAILS_COLLECTION, email_id);

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
            return Err(format!("Firestore get email error: {}", error_text).into());
        }

        let doc: Value = response.json().await?;
        let email = self.parse_email(&doc)?;
        Ok(Some(email))
    }

    /// Mark an email as read or unread
    pub async fn mark_email_read(
        &self,
        email_id: &str,
        read: bool,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!(
            "{}/{}/{}?updateMask.fieldPaths=read",
            self.base_url(),
            EMAILS_COLLECTION,
            email_id
        );

        let doc = json!({
            "fields": {
                "read": {"booleanValue": read}
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
            return Err(format!("Firestore mark email read error: {}", error_text).into());
        }

        Ok(())
    }

    /// Delete an email
    pub async fn delete_email(
        &self,
        email_id: &str,
    ) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let url = format!("{}/{}/{}", self.base_url(), EMAILS_COLLECTION, email_id);

        let response = self
            .build_request(reqwest::Method::DELETE, &url)
            .await?
            .send()
            .await?;

        if !response.status().is_success() && response.status() != reqwest::StatusCode::NOT_FOUND {
            let error_text = response.text().await?;
            return Err(format!("Firestore delete email error: {}", error_text).into());
        }

        Ok(())
    }

    /// Get total email count
    pub async fn get_email_count(&self) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
        let parent = self.base_url();

        let query = json!({
            "structuredQuery": {
                "from": [{"collectionId": EMAILS_COLLECTION}],
                "select": {"fields": [{"fieldPath": "__name__"}]}
            }
        });

        let url = format!("{}:runQuery", parent);

        let response = self
            .build_request(reqwest::Method::POST, &url)
            .await?
            .json(&query)
            .send()
            .await?;

        if !response.status().is_success() {
            return Ok(0);
        }

        let results: Vec<Value> = response.json().await?;
        // Count documents (excluding empty results)
        let count = results.iter().filter(|r| r.get("document").is_some()).count();
        Ok(count as i64)
    }

    /// Get unread email count
    pub async fn get_unread_email_count(
        &self,
    ) -> Result<i64, Box<dyn std::error::Error + Send + Sync>> {
        let parent = self.base_url();

        let query = json!({
            "structuredQuery": {
                "from": [{"collectionId": EMAILS_COLLECTION}],
                "where": {
                    "fieldFilter": {
                        "field": {"fieldPath": "read"},
                        "op": "EQUAL",
                        "value": {"booleanValue": false}
                    }
                },
                "select": {"fields": [{"fieldPath": "__name__"}]}
            }
        });

        let url = format!("{}:runQuery", parent);

        let response = self
            .build_request(reqwest::Method::POST, &url)
            .await?
            .json(&query)
            .send()
            .await?;

        if !response.status().is_success() {
            return Ok(0);
        }

        let results: Vec<Value> = response.json().await?;
        let count = results.iter().filter(|r| r.get("document").is_some()).count();
        Ok(count as i64)
    }

    /// Parse email document from Firestore response
    fn parse_email(&self, doc: &Value) -> Result<InboundEmailDB, Box<dyn std::error::Error + Send + Sync>> {
        let fields = doc
            .get("fields")
            .ok_or("Missing fields in email document")?;

        // Extract document ID from name
        let name = doc.get("name").and_then(|n| n.as_str()).unwrap_or("");
        let id = name.split('/').last().unwrap_or("").to_string();

        // Parse from
        let from_email = fields
            .get("from")
            .and_then(|v| v.get("stringValue"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();

        // Parse to array
        let to: Vec<String> = fields
            .get("to")
            .and_then(|v| v.get("arrayValue"))
            .and_then(|v| v.get("values"))
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.get("stringValue").and_then(|s| s.as_str()))
                    .map(|s| s.to_string())
                    .collect()
            })
            .unwrap_or_default();

        // Parse subject
        let subject = fields
            .get("subject")
            .and_then(|v| v.get("stringValue"))
            .and_then(|v| v.as_str())
            .unwrap_or("(no subject)")
            .to_string();

        // Parse text (optional)
        let text = fields
            .get("text")
            .and_then(|v| v.get("stringValue"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        // Parse html (optional)
        let html = fields
            .get("html")
            .and_then(|v| v.get("stringValue"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        // Parse received_at
        let received_at = fields
            .get("received_at")
            .and_then(|v| v.get("timestampValue"))
            .and_then(|v| v.as_str())
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
            .map(|dt| dt.with_timezone(&Utc))
            .unwrap_or_else(Utc::now);

        // Parse read
        let read = fields
            .get("read")
            .and_then(|v| v.get("booleanValue"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false);

        // Parse attachments
        let attachments: Vec<EmailAttachment> = fields
            .get("attachments")
            .and_then(|v| v.get("arrayValue"))
            .and_then(|v| v.get("values"))
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| {
                        let map = v.get("mapValue")?.get("fields")?;
                        Some(EmailAttachment {
                            filename: map
                                .get("filename")
                                .and_then(|v| v.get("stringValue"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("attachment")
                                .to_string(),
                            content_type: map
                                .get("content_type")
                                .and_then(|v| v.get("stringValue"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("application/octet-stream")
                                .to_string(),
                            size: map
                                .get("size")
                                .and_then(|v| v.get("integerValue"))
                                .and_then(|v| v.as_str())
                                .and_then(|s| s.parse().ok())
                                .unwrap_or(0),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        Ok(InboundEmailDB {
            id,
            from_email,
            to,
            subject,
            text,
            html,
            attachments,
            received_at,
            read,
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
