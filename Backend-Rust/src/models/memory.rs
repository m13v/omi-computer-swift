// Memory models - Copied from Python backend (models.py, database.py)

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::category::MemoryCategory;

/// A memory extracted from conversation - long-term knowledge about the user
/// Copied from Python Memory model
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Memory {
    /// The memory content (max 15 words)
    pub content: String,

    /// The category of the memory
    #[serde(default)]
    pub category: MemoryCategory,
}

/// Memory as stored in Firestore
/// Copied from Python MemoryDB model
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MemoryDB {
    pub id: String,
    pub uid: String,
    pub content: String,
    pub category: MemoryCategory,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub conversation_id: Option<String>,
    #[serde(default)]
    pub reviewed: bool,
    pub user_review: Option<bool>,
    #[serde(default = "default_visibility")]
    pub visibility: String,
    #[serde(default)]
    pub manually_added: bool,
    /// Scoring string for sorting: "{manual_boost}_{category_boost}_{timestamp}"
    pub scoring: Option<String>,
}

fn default_visibility() -> String {
    "private".to_string()
}

impl MemoryDB {
    /// Calculate memory scoring for sorting
    /// Format: "{manual_boost}_{category_boost}_{timestamp}"
    /// Higher scores appear first when sorted descending
    /// Copied from Python _calculate_memory_score
    pub fn calculate_scoring(
        category: &MemoryCategory,
        created_at: &DateTime<Utc>,
        manually_added: bool,
    ) -> String {
        let manual_boost = if manually_added { 1 } else { 0 };

        let category_boost = match category {
            MemoryCategory::Interesting => 1,
            MemoryCategory::System => 0,
            MemoryCategory::Manual => 1,
        };
        let cat_boost = 999 - category_boost;

        let timestamp = created_at.timestamp();

        format!("{:02}_{:03}_{:010}", manual_boost, cat_boost, timestamp)
    }
}
