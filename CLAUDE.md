# Claude Project Context

## Project Overview
Hartford - OMI Desktop App for macOS (Swift)

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
