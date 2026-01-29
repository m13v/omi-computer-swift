// Models module

pub mod action_item;
pub mod app;
pub mod category;
pub mod conversation;
pub mod focus_session;
pub mod memory;
pub mod message;
pub mod request;
pub mod user_settings;

pub use action_item::{ActionItemDB, ActionItemStatusResponse, CreateActionItemRequest, UpdateActionItemRequest};
pub use app::{
    App, AppCapabilityDef, AppCategory, AppReview, AppSummary, ChatTool, ExternalIntegration,
    ListAppsQuery, ProactiveNotification, SearchAppsQuery, SubmitReviewRequest, ToggleAppRequest,
    ToggleAppResponse, TriggerEvent, UserEnabledApp, get_app_capabilities, get_app_categories,
};
pub use category::{Category, MemoryCategory};
pub use conversation::{
    ActionItem, AppResult, Conversation, ConversationSource, ConversationStatus, Event, Structured,
    TranscriptSegment,
};
pub use memory::{
    CreateMemoryRequest, CreateMemoryResponse, EditMemoryRequest, Memory, MemoryDB,
    MemoryStatusResponse, ReviewMemoryRequest, UpdateVisibilityRequest,
};
pub use message::{
    ChatSession, GetMessagesQuery, Message, MessageAppQuery, MessageSender, MessageType,
    SendMessageRequest,
};
pub use request::{CreateConversationRequest, CreateConversationResponse};
pub use focus_session::{
    CreateFocusSessionRequest, DistractionEntry, FocusSessionDB, FocusSessionStatusResponse,
    FocusStats, FocusStatus, GetFocusSessionsQuery, GetFocusStatsQuery,
};
pub use user_settings::{
    DailySummarySettings, NotificationSettings, PrivateCloudSync, RecordingPermission,
    SetPrivateCloudSyncRequest, SetRecordingPermissionRequest, TranscriptionPreferences,
    UpdateDailySummaryRequest, UpdateLanguageRequest, UpdateNotificationSettingsRequest,
    UpdateTranscriptionPreferencesRequest, UserLanguage, UserProfile, UserSettingsResponse,
    UserSettingsStatusResponse,
};
