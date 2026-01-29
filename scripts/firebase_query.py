#!/usr/bin/env python3
"""
Quick Firebase query script for OMI Desktop development.

Usage:
    source /Users/matthewdi/omi/backend/venv/bin/activate
    python scripts/firebase_query.py [command]

Commands:
    conversations  - List recent conversations
    conversation <id> - Get specific conversation details
    stats - Show user stats
    fix-timestamps - Fix any string timestamps to proper Firestore timestamps
"""

import sys
import os

# Add path to use the omi backend venv's firebase-admin
sys.path.insert(0, '/Users/matthewdi/omi/backend')

import firebase_admin
from firebase_admin import credentials, firestore
from datetime import datetime, timezone

# Your user ID
USER_ID = 'bdYYRztuRfheEcjSxMdYnDyDeF13'

# Credentials path (try local first, then omi backend)
CREDS_PATHS = [
    os.path.join(os.path.dirname(__file__), '..', 'Backend-Rust', 'google-credentials.json'),
    '/Users/matthewdi/omi/backend/google-credentials.json',
]

def init_firebase():
    """Initialize Firebase connection."""
    for creds_path in CREDS_PATHS:
        if os.path.exists(creds_path):
            cred = credentials.Certificate(creds_path)
            try:
                firebase_admin.initialize_app(cred)
            except ValueError:
                pass  # Already initialized
            return firestore.client()
    raise FileNotFoundError("No google-credentials.json found")

def list_conversations(db, limit=10):
    """List recent conversations."""
    print(f"\n=== Recent Conversations for {USER_ID} ===\n")

    convos = db.collection('users').document(USER_ID).collection('conversations') \
        .order_by('created_at', direction=firestore.Query.DESCENDING) \
        .limit(limit) \
        .stream()

    for i, conv in enumerate(convos, 1):
        data = conv.to_dict()
        created = data.get('created_at', 'N/A')
        title = data.get('structured', {}).get('title', 'No title')[:50]
        source = data.get('source', 'unknown')
        status = data.get('status', 'unknown')
        segments = len(data.get('transcript_segments', []))

        print(f"[{i}] {conv.id}")
        print(f"    Title: {title}")
        print(f"    Created: {created}")
        print(f"    Source: {source} | Status: {status} | Segments: {segments}")
        print()

def get_conversation(db, conv_id):
    """Get specific conversation details."""
    print(f"\n=== Conversation {conv_id} ===\n")

    doc = db.collection('users').document(USER_ID).collection('conversations').document(conv_id).get()

    if not doc.exists:
        print("Conversation not found!")
        return

    data = doc.to_dict()

    print(f"ID: {doc.id}")
    print(f"Title: {data.get('structured', {}).get('title', 'No title')}")
    print(f"Overview: {data.get('structured', {}).get('overview', 'N/A')[:200]}...")
    print(f"Created: {data.get('created_at')}")
    print(f"Started: {data.get('started_at')}")
    print(f"Finished: {data.get('finished_at')}")
    print(f"Source: {data.get('source')}")
    print(f"Status: {data.get('status')}")
    print(f"Discarded: {data.get('discarded')}")
    print()

    segments = data.get('transcript_segments', [])
    print(f"Transcript Segments ({len(segments)}):")
    for i, seg in enumerate(segments[:10]):
        speaker = seg.get('speaker', 'Unknown')
        text = seg.get('text', '')[:60]
        print(f"  [{i}] {speaker}: {text}...")

    if len(segments) > 10:
        print(f"  ... and {len(segments) - 10} more segments")

def show_stats(db):
    """Show user stats."""
    print(f"\n=== Stats for {USER_ID} ===\n")

    # Count conversations by source
    convos = list(db.collection('users').document(USER_ID).collection('conversations').stream())

    sources = {}
    statuses = {}
    timestamp_types = {'string': 0, 'timestamp': 0}

    for conv in convos:
        data = conv.to_dict()
        source = data.get('source', 'unknown')
        status = data.get('status', 'unknown')
        created_at = data.get('created_at')

        sources[source] = sources.get(source, 0) + 1
        statuses[status] = statuses.get(status, 0) + 1

        if isinstance(created_at, str):
            timestamp_types['string'] += 1
        else:
            timestamp_types['timestamp'] += 1

    print(f"Total conversations: {len(convos)}")
    print()
    print("By source:")
    for source, count in sorted(sources.items(), key=lambda x: -x[1]):
        print(f"  {source}: {count}")
    print()
    print("By status:")
    for status, count in sorted(statuses.items(), key=lambda x: -x[1]):
        print(f"  {status}: {count}")
    print()
    print("Timestamp types (created_at):")
    print(f"  STRING: {timestamp_types['string']}")
    print(f"  TIMESTAMP: {timestamp_types['timestamp']}")

def fix_timestamps(db):
    """Fix string timestamps to proper Firestore timestamps."""
    print(f"\n=== Fixing String Timestamps for {USER_ID} ===\n")

    fixed = 0
    convos = list(db.collection('users').document(USER_ID).collection('conversations').stream())

    for conv in convos:
        data = conv.to_dict()
        created_at = data.get('created_at')

        if isinstance(created_at, str):
            dt = datetime.fromisoformat(created_at.replace('Z', '+00:00'))
            conv.reference.update({'created_at': dt})
            print(f"Fixed: {conv.id}")
            fixed += 1

    print(f"\nFixed {fixed} conversations")

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return

    db = init_firebase()
    command = sys.argv[1]

    if command == 'conversations':
        limit = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        list_conversations(db, limit)
    elif command == 'conversation':
        if len(sys.argv) < 3:
            print("Usage: python firebase_query.py conversation <id>")
            return
        get_conversation(db, sys.argv[2])
    elif command == 'stats':
        show_stats(db)
    elif command == 'fix-timestamps':
        fix_timestamps(db)
    else:
        print(f"Unknown command: {command}")
        print(__doc__)

if __name__ == '__main__':
    main()
