"""
Database operations for Firestore.
"""
import hashlib
from datetime import datetime, timezone
from typing import List, Optional
from firebase_admin import firestore


def document_id_from_seed(seed: str) -> str:
    """Generate a document ID from a seed string using SHA256 hash."""
    return hashlib.sha256(seed.encode()).hexdigest()[:20]


def get_firestore_client():
    """Get Firestore client."""
    return firestore.client()


def save_conversation(uid: str, conversation_data: dict) -> None:
    """
    Save a conversation to Firestore.
    Path: users/{uid}/conversations/{conversation_id}
    """
    db = get_firestore_client()
    conversation_id = conversation_data['id']

    user_ref = db.collection('users').document(uid)
    conversation_ref = user_ref.collection('conversations').document(conversation_id)
    conversation_ref.set(conversation_data)

    print(f"Saved conversation {conversation_id} for user {uid}")


def get_conversation(uid: str, conversation_id: str) -> dict:
    """
    Get a conversation from Firestore.
    """
    db = get_firestore_client()
    user_ref = db.collection('users').document(uid)
    conversation_ref = user_ref.collection('conversations').document(conversation_id)
    doc = conversation_ref.get()

    if doc.exists:
        return doc.to_dict()
    return None


def save_action_items(uid: str, conversation_id: str, action_items: List[dict]) -> List[str]:
    """
    Save action items to the dedicated action_items collection.
    Path: users/{uid}/action_items/{auto_id}

    Args:
        uid: User ID
        conversation_id: ID of the conversation these action items came from
        action_items: List of action item dicts with description, completed, due_at

    Returns:
        List of created action item IDs
    """
    if not action_items:
        return []

    db = get_firestore_client()
    user_ref = db.collection('users').document(uid)
    action_items_ref = user_ref.collection('action_items')

    now = datetime.now(timezone.utc)
    created_ids = []

    # Use batch for efficiency
    batch = db.batch()

    for item in action_items:
        doc_ref = action_items_ref.document()  # Auto-generate ID

        action_item_data = {
            'description': item.get('description', ''),
            'completed': item.get('completed', False),
            'created_at': now,
            'updated_at': now,
            'due_at': item.get('due_at'),  # Can be None
            'completed_at': None,
            'conversation_id': conversation_id,
        }

        batch.set(doc_ref, action_item_data)
        created_ids.append(doc_ref.id)

    batch.commit()
    print(f"Saved {len(created_ids)} action items for conversation {conversation_id}")

    return created_ids


def save_memories(uid: str, conversation_id: str, memories: List[dict]) -> List[str]:
    """
    Save memories to the dedicated memories collection.
    Path: users/{uid}/memories/{memory_id}

    Memory IDs are generated from content hash to enable deduplication.

    Args:
        uid: User ID
        conversation_id: ID of the conversation these memories came from
        memories: List of memory dicts with content and category

    Returns:
        List of created/updated memory IDs
    """
    if not memories:
        return []

    db = get_firestore_client()
    user_ref = db.collection('users').document(uid)
    memories_ref = user_ref.collection('memories')

    now = datetime.now(timezone.utc)
    saved_ids = []

    # Use batch for efficiency
    batch = db.batch()

    for mem in memories:
        content = mem.get('content', '')
        if not content:
            continue

        # Generate ID from content hash (enables deduplication)
        memory_id = document_id_from_seed(content)

        memory_data = {
            'id': memory_id,
            'uid': uid,
            'content': content,
            'category': mem.get('category', 'system'),
            'created_at': now,
            'updated_at': now,
            'conversation_id': conversation_id,
            'reviewed': True,  # Auto-extracted memories are pre-reviewed
            'user_review': None,  # Not yet reviewed by user
            'manually_added': False,
            'visibility': 'private',
            'scoring': _calculate_memory_score(mem.get('category', 'system'), now, False),
        }

        doc_ref = memories_ref.document(memory_id)
        batch.set(doc_ref, memory_data)
        saved_ids.append(memory_id)

    batch.commit()
    print(f"Saved {len(saved_ids)} memories for conversation {conversation_id}")

    return saved_ids


def _calculate_memory_score(category: str, created_at: datetime, manually_added: bool) -> str:
    """
    Calculate memory scoring for sorting.
    Format: "{manual_boost}_{category_boost}_{timestamp}"

    Higher scores appear first when sorted descending.
    """
    # Category boosts (interesting and manual get boost)
    category_boosts = {
        'interesting': 1,
        'system': 0,
        'manual': 1,
    }

    manual_boost = 1 if manually_added else 0
    cat_boost = 999 - category_boosts.get(category, 0)
    timestamp = int(created_at.timestamp())

    return f"{manual_boost:02d}_{cat_boost:03d}_{timestamp:010d}"


def get_memories(uid: str, limit: int = 100) -> List[dict]:
    """
    Get recent memories for a user.
    Used for deduplication context in memory extraction.

    Args:
        uid: User ID
        limit: Maximum number of memories to return

    Returns:
        List of memory dicts
    """
    db = get_firestore_client()
    user_ref = db.collection('users').document(uid)
    memories_ref = user_ref.collection('memories')

    # Order by scoring descending, then created_at descending
    query = (
        memories_ref
        .order_by('scoring', direction=firestore.Query.DESCENDING)
        .order_by('created_at', direction=firestore.Query.DESCENDING)
        .limit(limit)
    )

    memories = []
    for doc in query.stream():
        mem_data = doc.to_dict()
        # Filter out rejected memories
        if mem_data.get('user_review') is not False:
            memories.append(mem_data)

    return memories
