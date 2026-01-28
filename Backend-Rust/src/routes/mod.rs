// Routes module

pub mod auth;
pub mod conversations;
pub mod health;
pub mod memories;

use crate::AppState;

pub use auth::auth_routes;
pub use conversations::conversations_routes;
pub use health::health_routes;
pub use memories::memories_routes;
