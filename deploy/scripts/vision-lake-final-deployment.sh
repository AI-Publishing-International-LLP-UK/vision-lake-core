#!/bin/bash
# Vision Lake Final Deployment Script
# Deploys all components to Google Cloud Platform

set -e

# Configuration
PROJECT_ID="api-for-warp-drive"
REGION="us-west1"
ZONES=("us-west1-a" "us-west1-b" "us-west1-c")
SERVICE_NAMES=("payment-pipeline" "vision-space" "squadron-manager" "continuity-service")

# Check for GCP CLI and authentication
if ! command -v gcloud &> /dev/null; then
    echo "Error: gcloud CLI not found. Please install Google Cloud SDK."
    exit 1
fi

# Check if logged in
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
    echo "Error: Not authenticated with GCP. Please run 'gcloud auth login'"
    exit 1
fi

# Set project
echo "Setting project to $PROJECT_ID..."
gcloud config set project $PROJECT_ID

# Enable required APIs
echo "Enabling required APIs..."
gcloud services enable cloudbuild.googleapis.com cloudrun.googleapis.com \
    secretmanager.googleapis.com firestore.googleapis.com \
    compute.googleapis.com container.googleapis.com \
    artifactregistry.googleapis.com

# Create Artifact Registry repository
echo "Creating Artifact Registry repository..."
gcloud artifacts repositories create vision-lake \
    --repository-format=docker \
    --location=$REGION \
    --description="Vision Lake Docker repository"

# Set up Secret Manager secrets
echo "Setting up Secret Manager secrets..."
for SECRET in STRIPE_SECRET_KEY XERO_CLIENT_ID XERO_CLIENT_SECRET \
              PANDADOC_API_KEY FIREBASE_SERVICE_ACCOUNT \
              OPENAI_API_KEY GOOGLE_CLOUD_CREDENTIALS; do
    if ! gcloud secrets describe $SECRET &> /dev/null; then
        echo "Creating secret $SECRET..."
        gcloud secrets create $SECRET --replication-policy="automatic"
        echo "Please enter value for $SECRET:"
        read -s SECRET_VALUE
        echo $SECRET_VALUE | gcloud secrets versions add $SECRET --data-file=-
    fi
done

# Deploy MCP Compute Instances for Squadron Leaders
echo "Deploying MCP Compute Instances for Squadron Leaders..."
for ZONE in "${ZONES[@]}"; do
    for i in $(seq 1 3); do
        INSTANCE_NAME="squadron-leader-$ZONE-$i"
        
        # Check if instance exists
        if ! gcloud compute instances describe $INSTANCE_NAME --zone=$ZONE &> /dev/null; then
            echo "Creating instance $INSTANCE_NAME in $ZONE..."
            gcloud compute instances create $INSTANCE_NAME \
                --zone=$ZONE \
                --machine-type=e2-standard-4 \
                --image-family=debian-11 \
                --image-project=debian-cloud \
                --boot-disk-size=50GB \
                --tags=vision-lake,squadron-leader \
                --metadata=startup-script='#!/bin/bash
                    apt-get update
                    apt-get install -y docker.io git
                    systemctl start docker
                    systemctl enable docker
                    curl -L https://raw.githubusercontent.com/AI-Publishing-International-LLP-UK/vision-lake-core/main/deploy/scripts/squadron-setup.sh | bash
                '
        else
            echo "Instance $INSTANCE_NAME already exists in $ZONE, updating..."
            gcloud compute instances update $INSTANCE_NAME --zone=$ZONE
        fi
    done
done

# Create firewall rules
echo "Setting up firewall rules..."
gcloud compute firewall-rules create vision-lake-allow-ssh \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=vision-lake

# Deploy services to Cloud Run
echo "Deploying services to Cloud Run..."
for SERVICE in "${SERVICE_NAMES[@]}"; do
    echo "Building and deploying $SERVICE..."
    cd ~/vision-lake-20241220/src/$SERVICE
    
    # Build container
    gcloud builds submit --tag $REGION-docker.pkg.dev/$PROJECT_ID/vision-lake/$SERVICE
    
    # Get secrets to mount
    SECRETS_MOUNT=""
    if [ "$SERVICE" == "payment-pipeline" ]; then
        SECRETS_MOUNT="--set-secrets=STRIPE_SECRET_KEY=STRIPE_SECRET_KEY:latest,XERO_CLIENT_ID=XERO_CLIENT_ID:latest,XERO_CLIENT_SECRET=XERO_CLIENT_SECRET:latest,PANDADOC_API_KEY=PANDADOC_API_KEY:latest,FIREBASE_SERVICE_ACCOUNT=FIREBASE_SERVICE_ACCOUNT:latest"
    elif [ "$SERVICE" == "vision-space" ]; then
        SECRETS_MOUNT="--set-secrets=OPENAI_API_KEY=OPENAI_API_KEY:latest,FIREBASE_SERVICE_ACCOUNT=FIREBASE_SERVICE_ACCOUNT:latest"
    else
        SECRETS_MOUNT="--set-secrets=FIREBASE_SERVICE_ACCOUNT=FIREBASE_SERVICE_ACCOUNT:latest"
    fi
    
    # Deploy service
    gcloud run deploy $SERVICE \
        --image=$REGION-docker.pkg.dev/$PROJECT_ID/vision-lake/$SERVICE \
        --region=$REGION \
        $SECRETS_MOUNT \
        --memory=2Gi \
        --cpu=2 \
        --min-instances=1 \
        --max-instances=10 \
        --allow-unauthenticated
done

# Apply security patches for SSH vulnerability
echo "Applying security patches for SSH vulnerability..."
for ZONE in "${ZONES[@]}"; do
    gcloud compute ssh --zone=$ZONE squadron-leader-$ZONE-1 -- "sudo apt-get update && sudo apt-get install -y openssh-server && sudo systemctl restart ssh"
done

# Update DNS configuration
echo "Updating DNS configuration..."
gcloud dns record-sets create vision-lake.coaching2100.com. \
    --rrdatas="$(gcloud run services describe payment-pipeline --region=$REGION --format='value(status.url)' | sed 's/https:\/\///')" \
    --ttl=300 \
    --type=CNAME \
    --zone=main-zone

echo "Deployment complete! Vision Lake is now live at https://vision-lake.coaching2100.com"
