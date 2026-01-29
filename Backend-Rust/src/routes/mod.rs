// Routes module

pub mod action_items;
pub mod apps;
pub mod auth;
pub mod conversations;
pub mod health;
pub mod memories;
pub mod messages;

use crate::AppState;

pub use action_items::action_items_routes;
pub use apps::apps_routes;
pub use auth::auth_routes;
pub use conversations::conversations_routes;
pub use health::health_routes;
pub use memories::memories_routes;
pub use messages::messages_routes;
