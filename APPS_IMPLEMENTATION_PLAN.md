# Apps Feature Implementation Plan

This document outlines the implementation plan for reproducing the OMI apps/plugins functionality in the desktop app with a Rust backend.

---

## Implementation Progress

### Phase 1: Foundation - COMPLETED
- [x] **Models** - Created `Backend-Rust/src/models/app.rs` with all data structures
- [x] **Routes** - Created `Backend-Rust/src/routes/apps.rs` with all endpoints
- [x] **Firestore** - Added app-related methods to `Backend-Rust/src/services/firestore.rs`
- [x] **Integration** - Updated `mod.rs` files and `main.rs` to include apps routes

### Phase 2: Basic UI - COMPLETED
- [x] **Swift Models** - Added `OmiApp`, `OmiAppDetails`, `OmiAppCategory`, `OmiAppCapability`, `OmiAppReview` to `Desktop/Sources/APIClient.swift`
- [x] **API Client** - Added all app API methods (getApps, searchApps, enableApp, disableApp, etc.)
- [x] **AppProvider** - Created `Desktop/Sources/Providers/AppProvider.swift` for state management
- [x] **AppsPage** - Fully implemented apps marketplace UI in `Desktop/Sources/MainWindow/Pages/AppsPage.swift`
  - Search bar with debounced search
  - Filter toggle for installed apps
  - Popular apps section
  - Installed apps section
  - Category-grouped apps
  - App cards with icon, rating, install button
  - App detail sheet

### Phase 3: Enhanced UI - COMPLETED
- [x] Horizontal scrolling category sections
- [x] Filter sheet (rating, category filters)
- [x] "View All" category pages (via CategoryAppsSheet)
- [x] Loading shimmer states (ShimmerView, ShimmerAppCard)

### Phase 4: Chat Integration - COMPLETED
- [x] Chat app picker dropdown (AppPickerPopover)
- [x] Chat bubbles and messaging UI (ChatBubble, ChatMessage)
- [x] Typing indicator animation (TypingIndicator)
- [x] App response display (placeholder - needs backend streaming)

### Phase 5: Conversation Integration - COMPLETED
- [x] Show app results in conversation detail (AppResultCard component)
- [x] Reprocessing with different apps (AppSelectorSheet, reprocessConversation API)
- [x] Suggested apps for conversations (SuggestedAppCard, suggestedAppsSection)

**Backend additions:**
- Added `POST /v1/conversations/:id/reprocess` endpoint in `Backend-Rust/src/routes/conversations.rs`
- Added `run_memory_prompt` method to LLM client in `Backend-Rust/src/llm/client.rs`
- Added `add_app_result` method to Firestore service
- Added `AppResult` struct and `apps_results` field to `Conversation` model

**Swift additions:**
- Added `reprocessConversation` API method to `APIClient.swift`
- Enhanced `ConversationDetailView.swift` with:
  - `appResultsSection` - displays app insights with expandable cards
  - `suggestedAppsSection` - horizontal scroll of memory apps
  - `AppResultCard` - expandable card showing app analysis
  - `SuggestedAppCard` - compact app button for quick reprocessing
  - `AppSelectorSheet` - full app picker modal for reprocessing

---

---

## 1. Overview: How Apps Work

Apps in OMI are a **marketplace and plugin system** that extends the platform's functionality. They are third-party integrations that can:
- Act as chat assistants with custom personalities
- Analyze user conversations/memories
- Receive real-time data via webhooks
- Send proactive notifications to users

### App Capabilities

| Capability | What It Does | When Triggered |
|------------|--------------|----------------|
| `memories` | Analyzes/summarizes conversations | After conversation created |
| `chat` | Interactive chat assistant | User sends message |
| `persona` | AI personality clone | User sends message |
| `external_integration` | Webhook-based processing | Events (memory_creation, transcript_processed, audio_bytes) |
| `proactive_notification` | Sends notifications to user | App-initiated |

### Data Flow

```
User enables app → App stored in user's enabled list
     ↓
Event occurs (conversation created, chat message, etc.)
     ↓
Backend checks user's enabled apps with matching capability
     ↓
For each matching app:
  - If external_integration: POST webhook_url with data
  - If memories: Run app's memory_prompt against conversation
  - If chat: Run app's chat_prompt with message context
     ↓
Results returned to user (summary, chat response, notification)
```

---

## 2. Database Schema

### Apps Collection

```rust
struct App {
    id: String,
    name: String,
    description: String,
    image: String,                      // Icon URL
    category: String,
    author: String,
    email: Option<String>,
    capabilities: Vec<String>,          // ["chat", "memories", "persona", "external_integration", "proactive_notification"]
    approved: bool,
    private: bool,
    status: String,                     // "under-review", "approved", "rejected"
    uid: String,                        // Owner user ID

    // Prompts (for AI behavior)
    chat_prompt: Option<String>,
    memory_prompt: Option<String>,
    persona_prompt: Option<String>,

    // External integration config
    external_integration: Option<ExternalIntegration>,

    // Proactive notifications config
    proactive_notification: Option<ProactiveNotification>,

    // Stats
    installs: i32,
    rating_avg: Option<f32>,
    rating_count: i32,

    // Monetization
    is_paid: bool,
    price: Option<f32>,
    payment_plan: Option<String>,       // "monthly_recurring" or one-time

    created_at: DateTime,
}

struct ExternalIntegration {
    triggers_on: String,                // "memory_creation", "transcript_processed", "audio_bytes"
    webhook_url: String,
    setup_completed_url: Option<String>,
    auth_steps: Option<Vec<AuthStep>>,
    actions: Vec<String>,               // ["create_conversation", "read_memories", etc.]
}

struct ProactiveNotification {
    scopes: Vec<String>,                // ["user_name", "user_facts", "user_context", "user_chat"]
}

struct AppCategory {
    id: String,
    title: String,
}
```

### User Enabled Apps

```rust
struct UserEnabledApp {
    user_id: String,
    app_id: String,
    enabled_at: DateTime,
}
```

### App Reviews

```rust
struct AppReview {
    app_id: String,
    uid: String,
    score: i32,                         // 1-5
    review: String,
    response: Option<String>,           // Developer response
    rated_at: DateTime,
    edited_at: Option<DateTime>,
}
```

---

## 3. Rust Backend API Endpoints

### App Discovery

```
GET  /v2/apps                               # List apps (grouped by capability)
     ?capability={id}                       # Filter by capability
     ?category={id}                         # Filter by category
     ?include_reviews=true                  # Include reviews

GET  /v1/approved-apps                      # Public approved apps only
GET  /v1/apps/popular                       # Popular apps (ranked)
GET  /v2/apps/search                        # Full search
     ?query={text}
     &category={id}
     &rating={min}
     &capability={id}
     &sort={field}
     &my_apps={bool}
     &installed_apps={bool}
```

### App Details & Management

```
GET  /v1/apps/{app_id}                      # Get app details
POST /v1/apps                               # Create new app
PATCH /v1/apps/{app_id}                     # Update app
DELETE /v1/apps/{app_id}                    # Delete app
PATCH /v1/apps/{app_id}/change-visibility  # Toggle private/public
```

### App Installation

```
POST /v1/apps/enable                        # Enable app for user
     Body: { "app_id": "..." }

POST /v1/apps/disable                       # Disable app for user
     Body: { "app_id": "..." }
```

### App Usage (Chat)

```
POST /v2/messages?app_id={id}               # Chat with app (streaming SSE)
     Body: { "text": "..." }

GET  /v2/initial-message?app_id={id}        # Get app's intro message
```

### Conversation Reprocessing

```
POST /v1/conversations/{id}/reprocess       # Re-summarize with different app
     ?app_id={id}
```

### Reviews

```
POST /v1/apps/review                        # Submit review
     Body: { "app_id": "...", "score": 5, "review": "..." }

PATCH /v1/apps/{app_id}/review              # Update review
GET   /v1/apps/{app_id}/reviews             # Get all reviews
```

### Metadata

```
GET  /v1/app-categories                     # List all categories
GET  /v1/app-capabilities                   # List all capabilities
```

---

## 4. Swift Desktop Implementation

### File Structure

```
Desktop/Sources/
├── Models/
│   └── App.swift                           # App data models
├── Providers/
│   └── AppProvider.swift                   # State management
├── MainWindow/
│   └── Pages/
│       ├── Apps/
│       │   ├── AppsPage.swift              # Main apps view
│       │   ├── AppListItem.swift           # Single app row
│       │   ├── AppCategorySection.swift    # Horizontal category
│       │   ├── AppDetailView.swift         # Full app detail
│       │   └── AppFilterSheet.swift        # Filter modal
│       └── Chat/
│           └── ChatAppPicker.swift         # App selector for chat
└── APIClient.swift                         # Add app API methods
```

### Models (`Desktop/Sources/Models/App.swift`)

```swift
import Foundation

struct App: Codable, Identifiable {
    let id: String
    let name: String
    let description: String
    let image: String
    let category: String
    let author: String
    let capabilities: [String]
    var enabled: Bool
    let installs: Int
    let ratingAvg: Double?
    let ratingCount: Int?

    // Prompts
    let chatPrompt: String?
    let memoryPrompt: String?
    let personaPrompt: String?

    // External integration
    let externalIntegration: ExternalIntegration?

    // Monetization
    let isPaid: Bool?
    let price: Double?

    let createdAt: Date?

    var worksWithChat: Bool {
        capabilities.contains("chat") || capabilities.contains("persona")
    }

    var worksWithMemories: Bool {
        capabilities.contains("memories")
    }

    var worksExternally: Bool {
        capabilities.contains("external_integration")
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, image, category, author, capabilities
        case enabled, installs
        case ratingAvg = "rating_avg"
        case ratingCount = "rating_count"
        case chatPrompt = "chat_prompt"
        case memoryPrompt = "memory_prompt"
        case personaPrompt = "persona_prompt"
        case externalIntegration = "external_integration"
        case isPaid = "is_paid"
        case price
        case createdAt = "created_at"
    }
}

struct ExternalIntegration: Codable {
    let triggersOn: String
    let webhookUrl: String
    let setupCompletedUrl: String?
    let actions: [String]?

    enum CodingKeys: String, CodingKey {
        case triggersOn = "triggers_on"
        case webhookUrl = "webhook_url"
        case setupCompletedUrl = "setup_completed_url"
        case actions
    }
}

struct AppCategory: Codable, Identifiable {
    let id: String
    let title: String
}

struct AppCapability: Codable, Identifiable {
    let id: String
    let title: String
    let description: String
}

struct AppReview: Codable, Identifiable {
    var id: String { uid }
    let uid: String
    let score: Int
    let review: String
    let response: String?
    let ratedAt: Date

    enum CodingKeys: String, CodingKey {
        case uid, score, review, response
        case ratedAt = "rated_at"
    }
}

// Response types
struct AppsGroupedResponse: Codable {
    let byCapability: [String: [App]]?
    let byCategory: [String: [App]]?

    enum CodingKeys: String, CodingKey {
        case byCapability = "by_capability"
        case byCategory = "by_category"
    }
}
```

### API Client Extension

```swift
// Add to APIClient.swift

extension APIClient {
    // MARK: - App Discovery

    func getApps(capability: String? = nil, category: String? = nil) async throws -> [App] {
        var endpoint = "v2/apps"
        var queryItems: [String] = []
        if let capability { queryItems.append("capability=\(capability)") }
        if let category { queryItems.append("category=\(category)") }
        if !queryItems.isEmpty { endpoint += "?\(queryItems.joined(separator: "&"))" }
        return try await get(endpoint)
    }

    func getPopularApps() async throws -> [App] {
        return try await get("v1/apps/popular")
    }

    func searchApps(query: String?, category: String? = nil, minRating: Int? = nil,
                    capability: String? = nil, installedOnly: Bool = false) async throws -> [App] {
        var params: [String] = []
        if let query { params.append("query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)") }
        if let category { params.append("category=\(category)") }
        if let minRating { params.append("rating=\(minRating)") }
        if let capability { params.append("capability=\(capability)") }
        if installedOnly { params.append("installed_apps=true") }
        let endpoint = "v2/apps/search?\(params.joined(separator: "&"))"
        return try await get(endpoint)
    }

    func getAppCategories() async throws -> [AppCategory] {
        return try await get("v1/app-categories")
    }

    func getAppCapabilities() async throws -> [AppCapability] {
        return try await get("v1/app-capabilities")
    }

    // MARK: - App Details

    func getAppDetails(appId: String) async throws -> App {
        return try await get("v1/apps/\(appId)")
    }

    func getAppReviews(appId: String) async throws -> [AppReview] {
        return try await get("v1/apps/\(appId)/reviews")
    }

    // MARK: - App Management

    func enableApp(appId: String) async throws {
        struct EnableRequest: Codable { let app_id: String }
        let _: EmptyResponse = try await post("v1/apps/enable", body: EnableRequest(app_id: appId))
    }

    func disableApp(appId: String) async throws {
        struct DisableRequest: Codable { let app_id: String }
        let _: EmptyResponse = try await post("v1/apps/disable", body: DisableRequest(app_id: appId))
    }

    // MARK: - Chat with Apps

    func sendMessageToApp(appId: String, text: String) -> AsyncThrowingStream<String, Error> {
        // Streaming implementation for SSE
        AsyncThrowingStream { continuation in
            Task {
                // Implementation for server-sent events streaming
                // Similar to existing chat streaming if implemented
            }
        }
    }

    func getInitialAppMessage(appId: String) async throws -> String? {
        struct InitialMessageResponse: Codable { let message: String? }
        let response: InitialMessageResponse = try await post("v2/initial-message?app_id=\(appId)", body: EmptyBody())
        return response.message
    }
}

struct EmptyResponse: Codable {}
struct EmptyBody: Codable {}
```

### State Management (`Desktop/Sources/Providers/AppProvider.swift`)

```swift
import SwiftUI

@MainActor
class AppProvider: ObservableObject {
    @Published var apps: [App] = []
    @Published var popularApps: [App] = []
    @Published var categories: [AppCategory] = []
    @Published var capabilities: [AppCapability] = []

    @Published var enabledApps: [App] = []
    @Published var chatApps: [App] = []

    @Published var isLoading = false
    @Published var appLoadingStates: [String: Bool] = [:]  // appId -> loading

    @Published var selectedChatAppId: String?
    @Published var searchQuery: String = ""
    @Published var selectedCategory: String?
    @Published var showInstalledOnly: Bool = false

    private let apiClient = APIClient.shared

    // MARK: - Fetch Methods

    func fetchApps() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let appsTask = apiClient.getApps()
            async let popularTask = apiClient.getPopularApps()
            async let categoriesTask = apiClient.getAppCategories()

            let (fetchedApps, fetchedPopular, fetchedCategories) = try await (appsTask, popularTask, categoriesTask)

            apps = fetchedApps
            popularApps = fetchedPopular
            categories = fetchedCategories

            updateDerivedLists()
        } catch {
            log("Failed to fetch apps: \(error)")
        }
    }

    func searchApps() async {
        guard !searchQuery.isEmpty else {
            await fetchApps()
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            apps = try await apiClient.searchApps(
                query: searchQuery,
                category: selectedCategory,
                installedOnly: showInstalledOnly
            )
        } catch {
            log("Failed to search apps: \(error)")
        }
    }

    // MARK: - App Management

    func toggleApp(_ app: App) async {
        appLoadingStates[app.id] = true
        defer { appLoadingStates[app.id] = false }

        do {
            if app.enabled {
                try await apiClient.disableApp(appId: app.id)
            } else {
                try await apiClient.enableApp(appId: app.id)
            }

            // Update local state
            if let index = apps.firstIndex(where: { $0.id == app.id }) {
                apps[index].enabled.toggle()
            }
            updateDerivedLists()
        } catch {
            log("Failed to toggle app: \(error)")
        }
    }

    // MARK: - Helpers

    private func updateDerivedLists() {
        enabledApps = apps.filter { $0.enabled }
        chatApps = enabledApps.filter { $0.worksWithChat }
    }

    func isAppLoading(_ appId: String) -> Bool {
        appLoadingStates[appId] ?? false
    }
}
```

---

## 5. UI Components

### AppsPage (Main View)

```swift
struct AppsPage: View {
    @StateObject private var appProvider = AppProvider()
    @State private var searchText = ""
    @State private var showFilters = false

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar

            // Content
            if appProvider.isLoading {
                loadingView
            } else if appProvider.apps.isEmpty {
                emptyView
            } else {
                ScrollView {
                    LazyVStack(spacing: 24) {
                        // Popular section
                        if !appProvider.popularApps.isEmpty {
                            AppSection(title: "Popular", apps: appProvider.popularApps)
                        }

                        // Categories
                        ForEach(appProvider.categories) { category in
                            let categoryApps = appProvider.apps.filter { $0.category == category.id }
                            if !categoryApps.isEmpty {
                                AppSection(title: category.title, apps: categoryApps)
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .task {
            await appProvider.fetchApps()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(OmiColors.backgroundSecondary)
            .cornerRadius(8)

            Button(action: { showFilters.toggle() }) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.title2)
            }
        }
        .padding()
    }
}
```

### AppListItem

```swift
struct AppListItem: View {
    let app: App
    let onToggle: () -> Void
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            // App icon
            AsyncImage(url: URL(string: app.image)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(OmiColors.backgroundSecondary)
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.headline)
                Text(app.description)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                if let rating = app.ratingAvg {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                        Text(String(format: "%.1f", rating))
                            .font(.caption)
                        Text("(\(app.ratingCount ?? 0))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Action button
            Button(action: onToggle) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Text(app.enabled ? "Open" : "Get")
                        .font(.subheadline.weight(.medium))
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(app.enabled ? Color.gray : OmiColors.purple)
            .disabled(isLoading)
        }
        .padding(.vertical, 8)
    }
}
```

### AppSection (Horizontal Category)

```swift
struct AppSection: View {
    let title: String
    let apps: [App]
    let maxItems: Int = 9

    var displayedApps: [App] {
        Array(apps.prefix(maxItems))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.title2.weight(.semibold))
                Spacer()
                if apps.count > maxItems {
                    Button("View All") {
                        // Navigate to full category view
                    }
                    .font(.subheadline)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(displayedApps) { app in
                        AppCard(app: app)
                    }
                }
            }
        }
    }
}

struct AppCard: View {
    let app: App

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: URL(string: app.image)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 16)
                    .fill(OmiColors.backgroundSecondary)
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text(app.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text(app.category)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(width: 80)
    }
}
```

---

## 6. Implementation Order

### Phase 1: Foundation
1. **Models** - Create `App.swift` with all data structures
2. **API Client** - Add app-related endpoints
3. **AppProvider** - Basic state management

### Phase 2: Basic UI
4. **AppsPage** - Main marketplace view with list
5. **AppListItem** - Individual app display
6. **Enable/Disable** - App installation flow

### Phase 3: Enhanced UI
7. **AppSection** - Horizontal category sections
8. **AppDetailView** - Full app information page
9. **Search & Filters** - Search bar, filter sheet

### Phase 4: Chat Integration
10. **ChatAppPicker** - App selector dropdown for chat
11. **Streaming Messages** - Route messages to selected app

### Phase 5: Conversation Integration
12. **App Results Display** - Show summaries in conversation detail
13. **Reprocessing** - Switch summarization apps

---

## 7. Flutter Reference Files

For UI/UX reference, these Flutter files show the existing implementation:

| Feature | Flutter File |
|---------|-------------|
| Main apps page | `/Users/matthewdi/omi/app/lib/pages/apps/explore_install_page.dart` |
| App list item | `/Users/matthewdi/omi/app/lib/pages/apps/list_item.dart` |
| Category section | `/Users/matthewdi/omi/app/lib/pages/apps/widgets/category_section.dart` |
| Popular apps | `/Users/matthewdi/omi/app/lib/pages/apps/widgets/popular_apps_section.dart` |
| App detail | `/Users/matthewdi/omi/app/lib/pages/apps/app_detail/app_detail.dart` |
| Filter sheet | `/Users/matthewdi/omi/app/lib/pages/apps/widgets/filter_sheet.dart` |
| App provider | `/Users/matthewdi/omi/app/lib/providers/app_provider.dart` |
| App schema | `/Users/matthewdi/omi/app/lib/backend/schema/app.dart` |
| Chat integration | `/Users/matthewdi/omi/app/lib/pages/chat/page.dart` |
| Summary selection | `/Users/matthewdi/omi/app/lib/pages/conversation_detail/widgets/summarized_apps_sheet.dart` |

---

## 8. Backend Integration Notes

### For Rust Backend

The Rust backend needs to implement:

1. **App Storage** - CRUD operations for apps collection
2. **User Enabled Apps** - Track which apps each user has enabled
3. **App Execution**:
   - For `memories` capability: Run prompts against LLM with conversation data
   - For `chat` capability: Streaming chat with app's prompt context
   - For `external_integration`: HTTP POST to webhooks
4. **Search & Ranking** - Full-text search, popularity scoring
5. **Rate Limiting** - For proactive notifications (1 per 30s per app per user)

### API Authentication

All app endpoints require user authentication (Bearer token).

### Caching Strategy

- Cache app list (invalidate on changes)
- Cache popular apps separately
- Cache enabled apps per user
- Cache reviews/ratings
