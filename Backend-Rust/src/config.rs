// Configuration - Environment variables
// Copied from Python backend .env

use std::env;

/// Application configuration loaded from environment
#[derive(Clone)]
pub struct Config {
    /// Server port
    pub port: u16,
    /// Gemini API key for LLM calls
    pub gemini_api_key: Option<String>,
    /// Google Application Credentials path for Firestore
    pub google_application_credentials: Option<String>,
    /// Firebase project ID
    pub firebase_project_id: Option<String>,
    /// Firebase Web API key (for identity toolkit)
    pub firebase_api_key: Option<String>,
    /// Base API URL (for OAuth callbacks)
    pub base_api_url: Option<String>,
    /// Apple Sign-In Client ID (Services ID)
    pub apple_client_id: Option<String>,
    /// Apple Team ID
    pub apple_team_id: Option<String>,
    /// Apple Key ID (for client secret JWT)
    pub apple_key_id: Option<String>,
    /// Apple Private Key (PEM format)
    pub apple_private_key: Option<String>,
    /// Google OAuth Client ID
    pub google_client_id: Option<String>,
    /// Google OAuth Client Secret
    pub google_client_secret: Option<String>,
}

impl Config {
    /// Load configuration from environment variables
    pub fn from_env() -> Self {
        Self {
            port: env::var("PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(8080),
            gemini_api_key: env::var("GEMINI_API_KEY").ok(),
            google_application_credentials: env::var("GOOGLE_APPLICATION_CREDENTIALS").ok(),
            firebase_project_id: env::var("FIREBASE_PROJECT_ID").ok()
                .or_else(|| env::var("GCP_PROJECT_ID").ok()),
            firebase_api_key: env::var("FIREBASE_API_KEY").ok(),
            base_api_url: env::var("BASE_API_URL").ok(),
            apple_client_id: env::var("APPLE_CLIENT_ID").ok(),
            apple_team_id: env::var("APPLE_TEAM_ID").ok(),
            apple_key_id: env::var("APPLE_KEY_ID").ok(),
            apple_private_key: env::var("APPLE_PRIVATE_KEY").ok(),
            google_client_id: env::var("GOOGLE_CLIENT_ID").ok(),
            google_client_secret: env::var("GOOGLE_CLIENT_SECRET").ok(),
        }
    }

    /// Validate that required configuration is present
    pub fn validate(&self) -> Result<(), String> {
        if self.google_application_credentials.is_none() {
            tracing::warn!("GOOGLE_APPLICATION_CREDENTIALS not set - Firestore will use default credentials");
        }
        if self.gemini_api_key.is_none() {
            tracing::warn!("GEMINI_API_KEY not set - conversation processing will fail");
        }
        Ok(())
    }
}
