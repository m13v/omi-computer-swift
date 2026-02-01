// Models module

pub mod action_item;
pub mod advice;
pub mod app;
pub mod category;
pub mod chat_session;
pub mod conversation;
pub mod focus_session;
pub mod folder;
pub mod memory;
pub mod message;
pub mod request;
pub mod user_settings;

pub use action_item::{ActionItemDB, ActionItemsListResponse, ActionItemStatusResponse, BatchCreateActionItemsRequest, CreateActionItemRequest, UpdateActionItemRequest};
pub use advice::{AdviceCategory, AdviceDB, AdviceStatusResponse, CreateAdviceRequest, GetAdviceQuery, UpdateAdviceRequest};
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
pub use folder::{
    BulkMoveRequest, BulkMoveResponse, CreateFolderRequest, DeleteFolderQuery, Folder,
    MoveToFolderRequest, ReorderFoldersRequest, UpdateFolderRequest,
};
pub use memory::{
    CreateMemoryRequest, CreateMemoryResponse, EditMemoryRequest, GetMemoriesQuery, Memory,
    MemoryDB, MemoryStatusResponse, ReviewMemoryRequest, UpdateMemoryReadRequest,
    UpdateVisibilityRequest,
};
pub use message::{
    DeleteMessagesQuery, GetMessagesQuery, MessageDB, MessageStatusResponse, SaveMessageRequest,
    SaveMessageResponse,
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
pub use chat_session::{
    ChatSessionDB, ChatSessionStatusResponse, CreateChatSessionRequest, GetChatSessionsQuery,
    UpdateChatSessionRequest,
};
