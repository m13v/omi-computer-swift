---
name: release
description: Release a new version of OMI Desktop. Analyzes changes since last release, generates changelog, and runs the full release pipeline.
allowed-tools: Bash, Read, Edit, Grep
---

# OMI Desktop Release Skill

Release a new version of the OMI Desktop app with auto-generated changelog.

## Release Process

### Step 1: Get the last release version

```bash
git tag -l 'v*' | sort -V | tail -1
```

### Step 2: Get commits since last release

```bash
# Get commits since last tag
LAST_TAG=$(git tag -l 'v*' | sort -V | tail -1)
git log ${LAST_TAG}..HEAD --oneline --no-merges
```

### Step 3: Analyze changes and create changelog

Review the commits and create a concise changelog. Group changes by category:
- **New Features**: New functionality added
- **Improvements**: Enhancements to existing features
- **Bug Fixes**: Issues that were resolved
- **Other**: Refactoring, docs, etc.

Keep it user-friendly - focus on what users will notice, not internal changes.

### Step 4: Update release.sh with the changelog

Edit `release.sh` to update two places:

1. **GitHub Release Notes** (around line 423):
```bash
RELEASE_NOTES=$(cat <<EOF
## Omi Desktop v${VERSION}

### What's New
- Your changelog item 1
- Your changelog item 2

### Downloads
- **DMG Installer**: For fresh installs, download the DMG below
- **Auto-Update**: Existing users will receive this update automatically
EOF
)
```

2. **Sparkle Appcast Changelog** (around line 470):
```bash
"changelog": ["Changelog item 1", "Changelog item 2"],
```

### Step 5: Run the release

```bash
./release.sh [version]
```

If no version specified, it auto-increments the patch version.

### Step 6: Verify the release

After release completes:
1. Download the DMG from GitHub
2. Install and launch to verify it works
3. Check the appcast shows correct changelog:
   ```bash
   curl -s https://desktop-backend-hhibjajaja-uc.a.run.app/appcast.xml | head -30
   ```

## Quick Release Command

For a quick release with default changelog:
```bash
./release.sh
```

## Release Script Location

The main release script is at: `/Users/matthewdi/omi-desktop/release.sh`

## What release.sh Does (12 Steps)

1. Deploy Rust backend to Cloud Run
2. Build the Swift desktop app
3. Sign with Developer ID
4. Notarize with Apple
5. Staple notarization ticket
6. Create DMG installer
7. Sign DMG
8. Notarize DMG
9. Staple DMG
10. Create Sparkle ZIP for auto-updates
11. Publish to GitHub and register in Firestore
12. Trigger installation test

## Environment Requirements

The release requires these in `.env`:
- `NOTARIZE_PASSWORD` - Apple app-specific password
- `SPARKLE_PRIVATE_KEY` - EdDSA key for signing updates
- `RELEASE_SECRET` - Backend API secret
- `APPLE_PRIVATE_KEY` - For Apple Sign-In config
- Various Firebase/Google/Apple OAuth keys

## Troubleshooting

### Notarization fails with unsigned binary
The script now signs `ffmpeg` automatically. If other binaries are added, update the signing section in release.sh.

### GitHub release fails
Run `gh auth login` to re-authenticate.

### GCloud auth expires
Run `gcloud auth login` to re-authenticate.
