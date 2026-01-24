# OMI Desktop App - Complete Functionality List

## Authentication & Onboarding
- Firebase authentication (email/password, Google, Apple sign-in)
- Multi-step onboarding wizard (Auth → Name → Language → Permissions → Complete)
- User profile creation with name and bio
- Language/locale selection
- System permissions setup (microphone, screen capture, calendar, notifications)
- Device linking for multi-platform sync

## Recording & Audio Capture
- System audio capture via ScreenCaptureKit (macOS)
- Microphone input capture via AVAudioEngine
- Mixed audio recording (system + mic combined)
- Real-time audio level monitoring (mic and system levels)
- Audio format conversion to 16kHz mono PCM
- Silence detection with RMS threshold
- Echo prevention (mutes system audio when speakers active + mic silent)
- Recording pause/resume functionality
- Manual recording start/stop from UI
- Auto-start recording on app launch (configurable)
- Recording duration timer display
- Audio device selection and switching
- Device change monitoring during recording
- System sleep prevention during active recording

## Meeting Detection & Smart Recording
- Automatic meeting app detection (Zoom, Teams, Google Meet, Slack, WebEx, GoToMeeting)
- Browser-based meeting detection via window title analysis
- Microphone activity monitoring across applications
- Floating nub indicator when meeting detected
- Context-aware auto-stop based on recording source (manual, calendar, mic-only, mic-linked)
- Debounced meeting detection to prevent false positives
- One-click recording start from meeting nub

## Real-time Transcription
- WebSocket connection to transcription backend
- Streaming audio chunks (1-second frames)
- Real-time transcript segment updates
- Speaker identification and labeling
- Language detection
- On-device transcription option (Apple/Whisper)
- Cloud-based transcription (default)
- Auto-reconnection with exponential backoff
- Keep-alive mechanism for socket connection

## Conversations Management
- Conversation list view with date grouping (Today, Yesterday, Last Week)
- Conversation search with real-time filtering
- Conversation detail view (inline or full page)
- Daily productivity/engagement score display
- Star/favorite conversations
- Discard/soft-delete conversations
- Show/hide discarded conversations toggle
- Show/hide short conversations with configurable threshold
- Conversation merging (combine multiple conversations)
- Multi-select mode for bulk operations
- Folder organization for conversations
- Date range filtering
- In-progress recording status display
- Conversation summary generation
- Participant/speaker list display
- Full transcript view with timestamps

## AI Chat Interface
- Message list with chat bubbles
- Markdown rendering for AI responses
- Real-time streaming AI responses
- Message input with keyboard handling (Enter to send, Shift+Enter for newline)
- Voice message recording and sending
- File drag-and-drop upload
- File attachment preview
- Typing indicator during AI response
- App selector dropdown (chat with different apps)
- Message context extraction via regex
- Text selection and copy from AI messages
- Message actions menu (copy, delete, rate)
- Chat history persistence and caching
- Clear chat functionality

## Floating Chat Window
- Separate floating window for quick AI queries
- Screenshot capture for context
- Global keyboard shortcut activation
- Streaming AI response display
- Markdown rendering in floating window

## Action Items & Tasks
- Action item list with category grouping (Today, Tomorrow, No Deadline, Later)
- Task creation with title, description, due date, priority
- Task completion (mark as done)
- Task deletion
- Multi-select mode for bulk operations
- Bulk complete/delete actions
- Drag-and-drop reordering
- Task hierarchy with indent levels (0-3)
- Show/hide completed tasks toggle
- Task search and filtering
- Due date reminders via push notifications
- Integration with external task managers (Todoist, Asana, ClickUp, Google Tasks)

## Apps & Integrations
- App grid display with icons and metadata
- App search with debouncing
- Category-based app filtering
- Popular/recommended apps section
- App detail view (description, capabilities, ratings, screenshots)
- App installation/uninstallation
- Custom app creation
- AI-powered app generation from prompts
- OAuth flow handling for integrations
- App capabilities (chat, memory, notifications)
- Integration status tracking

## Third-Party Integrations
- Todoist task sync (OAuth)
- Asana task sync
- ClickUp task sync
- Google Tasks sync
- Apple Reminders sync
- Google Calendar integration
- Notion integration
- GitHub integration
- Twitter integration
- Deep link callback handling for OAuth

## Memories
- Memory list view with categories (System-detected, Interesting, Manual, All)
- Memory search functionality
- Memory detail dialog with full context
- Memory creation from conversation highlights
- Memory management (edit, delete, categorize)
- Memory export options (text, PDF, share link, clipboard)
- Bulk memory operations
- Date range filtering
- Associated conversation linking

## Calendar Integration
- Apple Calendar monitoring
- Upcoming meeting display
- Meeting title in menu bar (optional)
- Calendar event notifications
- Meeting snooze functionality
- Multi-calendar support
- Calendar permission management

## Floating Control Bar
- Always-on-top recording controls
- Recording duration timer
- Play/pause button with state tracking
- Stop recording button
- Ask AI button (with screenshot capability)
- File selector button
- Hide bar button
- Animated recording indicator (red dot)
- Draggable window positioning

## Menu Bar Integration
- Status bar icon (Omi logo)
- Context menu with quick actions
- Show/hide main window
- Open floating chat
- Toggle control bar
- Keyboard shortcuts viewer
- Quit application
- Meeting title display in menu bar

## Keyboard Shortcuts
- Configurable global shortcuts
- Ask AI shortcut (default: Cmd+Shift+O)
- Toggle Control Bar shortcut (default: Cmd+Option+O)
- Shortcut conflict detection
- Shortcut persistence to UserDefaults
- Shortcut customization UI

## Window Management
- Frameless window with transparent titlebar
- Custom window controls (close, minimize, maximize)
- Rounded corners (18pt radius) with shadow
- Window state persistence
- Minimum window size enforcement (1100x700)
- Default window size (1300x800)
- Movable by window background
- Window restoration support

## Settings & Preferences
- User profile editing (name, bio, photo)
- Language preference selection
- Auto-recording toggle
- Show discarded conversations toggle
- Short conversation threshold configuration
- Keyboard shortcuts configuration
- About page with version info
- Developer mode toggle
- Debug logging enable/disable
- Log file viewing and export

## Permissions Management
- Microphone permission check/request
- Screen capture permission (ScreenCaptureKit)
- Bluetooth permission
- Location permission
- Notification permission
- Calendar access permission
- Accessibility permission (for window title detection)
- Permission status display in onboarding
- Graceful degradation if permissions denied

## Notifications
- Firebase Cloud Messaging (FCM) integration
- Local notification support
- Action item reminder notifications
- Important conversation alerts
- Merge completion notifications
- Notification channel configuration
- Background message handling
- Notification token management

## Data Persistence & Sync
- SharedPreferences for user settings
- Conversation caching for offline access
- Message caching
- App list caching
- Write-ahead log (WAL) for transaction durability
- Offline-first capability with sync on reconnect
- Delta sync for efficiency
- Conflict resolution

## Analytics & Monitoring
- Mixpanel event tracking
- Firebase Crashlytics crash reporting
- GrowthBook feature flags
- A/B testing support
- User identification for analytics
- Custom event logging
- Error alerting in development

## Auto-Update
- Sparkle framework integration (macOS)
- Background update checking
- Automatic installation
- Update notification display

## System Integration
- Deep link handling (app:// URL scheme)
- Universal links support
- Remote notification registration
- System sleep/wake event handling
- Screen lock/unlock detection
- App lifecycle management
- Clipboard access (pasteboard)
- Drag-and-drop file support

## Bluetooth & Device Support
- BLE device scanning and connection
- Omi hardware device pairing
- Device battery monitoring
- Firmware version checking
- Nordic DFU firmware updates
- MCU manager protocol support
- Frame glasses integration (SDK)

## Developer Tools
- Debug logging to file
- Log viewer UI
- API endpoint override
- Feature flag overrides
- Analytics debug mode
- Developer settings page
