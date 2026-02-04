// Redis service for conversation visibility
// Mirrors the Python backend's redis_db.py functionality for sharing conversations

use redis::{AsyncCommands, Client, ConnectionAddr, ConnectionInfo, RedisConnectionInfo};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Redis service for conversation visibility and sharing
pub struct RedisService {
    client: Client,
    connection: Arc<RwLock<Option<redis::aio::MultiplexedConnection>>>,
}

impl RedisService {
    /// Create a new Redis service with explicit connection parameters
    /// This avoids URL encoding issues with special characters in passwords
    pub fn new_with_params(host: &str, port: u16, password: Option<&str>) -> Result<Self, redis::RedisError> {
        let info = ConnectionInfo {
            addr: ConnectionAddr::Tcp(host.to_string(), port),
            redis: RedisConnectionInfo {
                db: 0,
                username: Some("default".to_string()),
                password: password.map(|p| p.to_string()),
            },
        };
        let client = Client::open(info)?;
        Ok(Self {
            client,
            connection: Arc::new(RwLock::new(None)),
        })
    }

    /// Create a new Redis service from URL (legacy, may have encoding issues)
    pub fn new(redis_url: &str) -> Result<Self, redis::RedisError> {
        let client = Client::open(redis_url)?;
        Ok(Self {
            client,
            connection: Arc::new(RwLock::new(None)),
        })
    }

    /// Get or create a connection
    async fn get_connection(&self) -> Result<redis::aio::MultiplexedConnection, redis::RedisError> {
        // Check if we have a cached connection
        {
            let conn = self.connection.read().await;
            if let Some(c) = conn.as_ref() {
                return Ok(c.clone());
            }
        }

        // Create new connection
        let conn = self.client.get_multiplexed_async_connection().await?;

        // Cache it
        {
            let mut cached = self.connection.write().await;
            *cached = Some(conn.clone());
        }

        Ok(conn)
    }

    // ============================================================================
    // CONVERSATION VISIBILITY - matches Python backend redis_db.py
    // ============================================================================

    /// Store conversation_id -> uid mapping for visibility lookup
    /// Key format: memories-visibility:{conversation_id}
    pub async fn store_conversation_to_uid(
        &self,
        conversation_id: &str,
        uid: &str,
    ) -> Result<(), redis::RedisError> {
        let mut conn = self.get_connection().await?;
        let key = format!("memories-visibility:{}", conversation_id);
        let _: () = conn.set(&key, uid).await?;
        tracing::info!("Stored conversation visibility: {} -> {}", conversation_id, uid);
        Ok(())
    }

    /// Remove conversation_id -> uid mapping
    pub async fn remove_conversation_to_uid(
        &self,
        conversation_id: &str,
    ) -> Result<(), redis::RedisError> {
        let mut conn = self.get_connection().await?;
        let key = format!("memories-visibility:{}", conversation_id);
        let _: () = conn.del(&key).await?;
        tracing::info!("Removed conversation visibility: {}", conversation_id);
        Ok(())
    }

    /// Get the uid that owns a public conversation
    /// Returns None if conversation is not public/shared
    pub async fn get_conversation_uid(
        &self,
        conversation_id: &str,
    ) -> Result<Option<String>, redis::RedisError> {
        let mut conn = self.get_connection().await?;
        let key = format!("memories-visibility:{}", conversation_id);
        let uid: Option<String> = conn.get(&key).await?;
        Ok(uid)
    }

    /// Add conversation to the public conversations set
    /// Key: public-memories (SET)
    pub async fn add_public_conversation(
        &self,
        conversation_id: &str,
    ) -> Result<(), redis::RedisError> {
        let mut conn = self.get_connection().await?;
        let _: () = conn.sadd("public-memories", conversation_id).await?;
        tracing::info!("Added conversation to public set: {}", conversation_id);
        Ok(())
    }

    /// Remove conversation from the public conversations set
    pub async fn remove_public_conversation(
        &self,
        conversation_id: &str,
    ) -> Result<(), redis::RedisError> {
        let mut conn = self.get_connection().await?;
        let _: () = conn.srem("public-memories", conversation_id).await?;
        tracing::info!("Removed conversation from public set: {}", conversation_id);
        Ok(())
    }

    /// Get all public conversation IDs
    pub async fn get_public_conversations(&self) -> Result<Vec<String>, redis::RedisError> {
        let mut conn = self.get_connection().await?;
        let ids: Vec<String> = conn.smembers("public-memories").await?;
        Ok(ids)
    }

    /// Check if Redis connection is healthy
    pub async fn health_check(&self) -> Result<bool, redis::RedisError> {
        let mut conn = self.get_connection().await?;
        let pong: String = redis::cmd("PING").query_async(&mut conn).await?;
        Ok(pong == "PONG")
    }

    // ============================================================================
    // APP INSTALLS - matches Python backend redis_db.py
    // ============================================================================

    /// Get installs count for multiple apps
    /// Key format: plugins:{app_id}:installs
    /// Returns a HashMap of app_id -> installs count
    pub async fn get_apps_installs_count(
        &self,
        app_ids: &[String],
    ) -> Result<std::collections::HashMap<String, i32>, redis::RedisError> {
        if app_ids.is_empty() {
            return Ok(std::collections::HashMap::new());
        }

        let mut conn = self.get_connection().await?;
        let keys: Vec<String> = app_ids
            .iter()
            .map(|id| format!("plugins:{}:installs", id))
            .collect();

        let counts: Vec<Option<String>> = conn.mget(&keys).await?;

        let result: std::collections::HashMap<String, i32> = app_ids
            .iter()
            .zip(counts.iter())
            .map(|(id, count)| {
                let installs = count
                    .as_ref()
                    .and_then(|s| s.parse::<i32>().ok())
                    .unwrap_or(0);
                (id.clone(), installs)
            })
            .collect();

        Ok(result)
    }
}
