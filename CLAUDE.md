# Claude Project Context

## Project Overview
OMI Desktop App for macOS (Swift)

## Logs
- **App log file**: `/private/tmp/omi.log`

## Related Repositories
- **OMI Main Repo**: `/Users/matthewdi/omi`
  - Backend: `/Users/matthewdi/omi/backend` (FastAPI Python)
  - Flutter App: `/Users/matthewdi/omi/app`

## Firebase Connection
Use `/firebase` command or see `.claude/skills/firebase/SKILL.md`

Quick connect:
```bash
cd /Users/matthewdi/omi/backend && source venv/bin/activate && python3 -c "
import firebase_admin
from firebase_admin import credentials, firestore, auth
cred = credentials.Certificate('google-credentials.json')
try: firebase_admin.initialize_app(cred)
except ValueError: pass
db = firestore.client()
print('Connected to Firebase: based-hardware')
"
```

## Key Architecture Notes

### Authentication
- Firebase Auth with Apple/Google Sign-In
- Desktop apps should use backend OAuth flow: `/v1/auth/authorize`
- Apple Services ID: `me.omi.web` (shared across all apps)
- iOS apps use native Sign-In, Desktop uses backend OAuth + custom token

### Database Structure
- **Firestore** (`based-hardware`): User data, conversations, action items
- **Redis**: Caching
- **Typesense**: Search

### User Subcollections (Firestore)
- `users/{uid}/conversations` - Has `source` field (omi, desktop, phone, etc.)
- `users/{uid}/action_items` - Tasks (no platform tracking)
- `users/{uid}/fcm_tokens` - Token ID prefix = platform (ios_, android_, macos_)
- `users/{uid}/memories` - Extracted memories

### Platform Detection
- **FCM tokens**: Document ID prefix (e.g., `macos_abc123`)
- **Conversations**: `source` field
- **Action items**: No platform tracking

### Known Limitations
- Firestore has no collection group indexes for `source` field
- Counting users by platform requires iterating all users (slow)
- Apple Sign-In: Only one Services ID per Firebase project

## API Endpoints
- Production: `https://api.omi.me`
- Local: `http://localhost:8080`

## Credentials
See `.claude/settings.json` for connection details.

## Development Workflow

### After Implementing Changes
- **DO NOT** run build commands (`swift build`, `xcodebuild`, etc.) after making changes
- **DO NOT** run the app after making changes
- Let the user build, run, and test the app manually
- Wait for user feedback before making additional changes

## SwiftUI macOS Patterns

### Click-Through Prevention for Sheets/Modals

**CRITICAL**: On macOS, when dismissing sheets or modals, click events can "fall through" to underlying views, causing the cursor to jump and trigger unintended clicks. This happens because the dismiss animation and click event complete at different times.

**Always use `SafeDismissButton` for sheet dismiss buttons** (defined in `AppsPage.swift`):
```swift
SafeDismissButton(dismiss: dismiss)
```

**For interactive elements that dismiss sheets**, use the async delay pattern:
```swift
.onTapGesture {
    // Resign first responder to consume the click
    NSApp.keyWindow?.makeFirstResponder(nil)
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms delay
        // Then perform action (dismiss, show another sheet, etc.)
        onTap()
    }
}
```

**Key rules:**
1. Never use `Button(action:)` for sheet dismiss actions - use `onTapGesture` with async delay
2. Always call `NSApp.keyWindow?.makeFirstResponder(nil)` before the delay
3. Use at least 100ms delay before triggering sheet transitions
4. When transitioning between sheets, dismiss first, then use `DispatchQueue.main.asyncAfter` with 0.3s delay before showing the next sheet

**Example of sheet-to-sheet transition:**
```swift
onCreatePersona: {
    showFirstSheet = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        showSecondSheet = true
    }
}
```

**Current implementation details (SafeDismissButton in AppsPage.swift):**
- Uses `@State private var isPressed` to prevent double-taps
- Sends a synthetic `leftMouseUp` event to consume pending clicks
- Uses 250ms delay before calling `dismiss()`
- Has extensive logging with `log("DISMISS: ...")` prefix

**Known issue:** Even with these measures, click-through can still occur during the sheet dismissal animation. The root cause is that macOS delivers mouse events to views that become visible during animation. Further investigation may be needed.
