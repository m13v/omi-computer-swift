"""
Database operations for Firestore.
"""
from firebase_admin import firestore


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
