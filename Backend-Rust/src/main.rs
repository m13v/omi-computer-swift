// OMI Desktop Backend - Rust
// Port from Python backend (main.py)

use axum::Router;
use std::fs::OpenOptions;
use std::io::{LineWriter, Write as IoWrite};
use std::sync::Arc;
use tower_http::cors::{Any, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing_subscriber::fmt::format::Writer;
use tracing_subscriber::fmt::time::FormatTime;
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt};
use std::fmt::Write as FmtWrite;

/// Custom time formatter: [HH:mm:ss] [backend]
#[derive(Clone)]
struct BackendTimer;

impl FormatTime for BackendTimer {
    fn format_time(&self, w: &mut Writer<'_>) -> std::fmt::Result {
        let now = chrono::Utc::now();
        write!(w, "[{}] [backend]", now.format("%H:%M:%S"))
    }
}

mod auth;
mod config;
mod llm;
mod models;
mod routes;
mod services;

use auth::{firebase_auth_extension, FirebaseAuth};
use config::Config;
use routes::{action_items_routes, apps_routes, auth_routes, conversations_routes, focus_sessions_routes, health_routes, memories_routes, messages_routes, users_routes};
use services::{FirestoreService, IntegrationService};

/// Application state shared across handlers
#[derive(Clone)]
pub struct AppState {
    pub firestore: Arc<FirestoreService>,
    pub integrations: Arc<IntegrationService>,
    pub config: Arc<Config>,
}

#[tokio::main]
async fn main() {
    // Open log file (same as Swift app: /tmp/omi.log)
    // Wrap in LineWriter to flush after each line (ensures logs appear immediately)
    let log_file = OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/omi.log")
        .expect("Failed to open log file");
    let line_writer = LineWriter::new(log_file);

    // Use non_blocking for proper async file writing
    let (non_blocking, _guard) = tracing_appender::non_blocking(line_writer);

    // Initialize tracing with both stdout and file output
    // Format: [HH:mm:ss] [backend] message
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "omi_desktop_backend=info,tower_http=info".into()),
        )
        // Stdout layer
        .with(
            fmt::layer()
                .with_timer(BackendTimer)
                .with_target(false)
                .with_level(false)
                .with_ansi(true)
        )
        // File layer (same format, no ANSI colors)
        .with(
            fmt::layer()
                .with_timer(BackendTimer)
                .with_target(false)
                .with_level(false)
                .with_ansi(false)
                .with_writer(non_blocking)
        )
        .init();

    // Load environment variables
    dotenvy::dotenv().ok();

    // Load and validate config
    let config = Config::from_env();
    if let Err(e) = config.validate() {
        tracing::error!("Configuration error: {}", e);
    }

    // Initialize Firebase Auth
    let firebase_auth = Arc::new(FirebaseAuth::new(
        config.firebase_project_id.clone().unwrap_or_else(|| "based-hardware".to_string()),
    ));

    // Refresh Firebase keys
    if let Err(e) = firebase_auth.refresh_keys().await {
        tracing::warn!("Failed to fetch Firebase keys: {} - auth may not work", e);
    }

    // Initialize Firestore
    let firestore = match FirestoreService::new(
        config.firebase_project_id.clone().unwrap_or_else(|| "based-hardware".to_string()),
    ).await {
        Ok(fs) => Arc::new(fs),
        Err(e) => {
            tracing::warn!("Failed to initialize Firestore: {} - using placeholder", e);
            Arc::new(FirestoreService::new("based-hardware".to_string()).await.unwrap())
        }
    };

    // Initialize Integration Service
    let integrations = Arc::new(IntegrationService::new());

    // Create app state
    let state = AppState {
        firestore,
        integrations,
        config: Arc::new(config.clone()),
    };

    // Build CORS layer
    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    // Build auth router (has its own state)
    let auth_router = auth_routes(state.config.clone());

    // Build main app router with AppState
    let main_router = Router::new()
        .merge(health_routes())
        .merge(memories_routes())
        .merge(conversations_routes())
        .merge(action_items_routes())
        .merge(focus_sessions_routes())
        .merge(apps_routes())
        .merge(messages_routes())
        .merge(users_routes())
        .with_state(state);

    // Merge both (now both are Router<()>), then add layers
    let app = main_router
        .merge(auth_router)
        .layer(firebase_auth_extension(firebase_auth))
        .layer(cors)
        .layer(TraceLayer::new_for_http());

    // Start server
    let addr = format!("0.0.0.0:{}", config.port);
    tracing::info!("Starting OMI Desktop Backend on {}", addr);

    let listener = tokio::net::TcpListener::bind(&addr).await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
