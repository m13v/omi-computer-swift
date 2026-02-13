# OMI Desktop

macOS app for OMI — always-on AI companion. Swift/SwiftUI frontend, Rust backend.

## Structure

```
Desktop/          Swift/SwiftUI macOS app
Backend-Rust/     Rust API server (Firestore, Redis, auth, LLM)
agent-bridge/     Claude agent integration (TypeScript)
agent-cloud/      Cloud agent service
dmg-assets/       DMG installer resources
docs/             Documentation
```

## Development

Requires macOS 14.0+, Swift 5.9+, Rust toolchain.

```bash
# Full dev run (builds app + backend + tunnel)
./run.sh

# Build release .app only
./build.sh
```

`run.sh` handles everything: builds the Swift app, starts the Rust backend, sets up a Cloudflare tunnel, and launches the app.

## License

MIT
