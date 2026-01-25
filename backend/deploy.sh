#!/bin/bash
set -e

# Configuration
PROJECT_ID="${GCP_PROJECT:-based-hardware}"
REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="omi-desktop-auth"
IMAGE_NAME="gcr.io/$PROJECT_ID/$SERVICE_NAME"

echo "=== OMI Desktop Auth Backend - Cloud Run Deployment ==="
echo ""
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Service: $SERVICE_NAME"
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "Error: .env file not found"
    exit 1
fi

# Check if gcloud is authenticated
if ! gcloud auth print-identity-token &>/dev/null; then
    echo "Error: Not authenticated with gcloud. Run: gcloud auth login"
    exit 1
fi

# Set project
gcloud config set project $PROJECT_ID

# Build and push Docker image
echo "[1/4] Building and pushing Docker image..."
gcloud builds submit --tag $IMAGE_NAME .

# Load environment variables from .env
echo "[2/4] Loading environment variables..."
source .env

# Read Firebase credentials JSON and escape it
FIREBASE_CREDS_JSON=""
if [ -f "google-credentials.json" ]; then
    FIREBASE_CREDS_JSON=$(cat google-credentials.json | tr -d '\n')
fi

# Deploy to Cloud Run
echo "[3/4] Deploying to Cloud Run..."

# First deploy to get the URL
gcloud run deploy $SERVICE_NAME \
    --image $IMAGE_NAME \
    --region $REGION \
    --platform managed \
    --allow-unauthenticated \
    --memory 512Mi \
    --timeout 60 \
    --set-env-vars "APPLE_CLIENT_ID=$APPLE_CLIENT_ID" \
    --set-env-vars "APPLE_TEAM_ID=$APPLE_TEAM_ID" \
    --set-env-vars "APPLE_KEY_ID=$APPLE_KEY_ID" \
    --set-env-vars "GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID" \
    --set-env-vars "GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET" \
    --set-env-vars "FIREBASE_API_KEY=$FIREBASE_API_KEY" \
    --quiet

# Get the service URL
SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --region $REGION --format 'value(status.url)')

# Update with BASE_API_URL and secrets that need special handling
echo "[4/4] Updating with final configuration..."
gcloud run services update $SERVICE_NAME \
    --region $REGION \
    --set-env-vars "BASE_API_URL=$SERVICE_URL" \
    --set-env-vars "^##^APPLE_PRIVATE_KEY=$APPLE_PRIVATE_KEY" \
    --set-env-vars "^##^FIREBASE_CREDENTIALS_JSON=$FIREBASE_CREDS_JSON" \
    --quiet

echo ""
echo "=== Deployment Complete ==="
echo ""
echo "Service URL: $SERVICE_URL"
echo ""
echo "IMPORTANT - Add these redirect URIs:"
echo ""
echo "Google Cloud Console (OAuth 2.0):"
echo "  ${SERVICE_URL}/v1/auth/callback/google"
echo ""
echo "Apple Developer Console (Sign in with Apple):"
echo "  ${SERVICE_URL}/v1/auth/callback/apple"
echo ""
echo "Update Swift app AuthService.swift apiBaseURL to:"
echo "  $SERVICE_URL"
echo ""
