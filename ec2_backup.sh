#!/bin/bash

# Variables
INSTANCE_ID="i-04452c50049ed431c"  # Replace with your instance ID
BUCKET_NAME="venkatbyte"  # Replace with your S3 bucket name
DATE=$(date +%F-%H-%M-%S)
AMI_NAME="Backup-$DATE"

# Configuration
CHECK_INTERVAL=30  # Check every 30 seconds
MAX_WAIT_TIME=300  # Maximum wait time in seconds (5 minutes)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "$1"
}

# Function to check AMI state
check_ami_state() {
    aws ec2 describe-images --image-ids "$AMI_ID" --query 'Images[0].State' --output text 2>/dev/null
}

# Step 1: Create AMI
log "Creating AMI for instance $INSTANCE_ID..."
AMI_ID=$(aws ec2 create-image --instance-id $INSTANCE_ID --name "$AMI_NAME" --description "Backup on $DATE" --no-reboot --output text --query 'ImageId')

if [ $? -eq 0 ] && [ -n "$AMI_ID" ]; then
    log "${GREEN}✓ AMI $AMI_ID created for instance $INSTANCE_ID with name $AMI_NAME${NC}"
else
    log "${RED}Error creating AMI${NC}" >&2
    exit 1
fi

# Step 2: Monitor AMI creation progress
log "Monitoring AMI creation progress..."

# Initialize counters
elapsed_time=0
checks_performed=0

# Main monitoring loop
while true; do
    checks_performed=$((checks_performed + 1))
    log "Check #$checks_performed: Checking AMI state..."
    
    # Get current AMI state
    current_state=$(check_ami_state)
    
    # Handle empty response (API error)
    if [[ -z "$current_state" ]]; then
        log "${RED}Error: Unable to retrieve AMI state${NC}"
        exit 1
    fi
    
    # Check if AMI is available
    if [[ "$current_state" == "available" ]]; then
        log "${GREEN}✓ AMI is now available! Proceeding with create-store-image-task...${NC}"
        break
    fi
    
    # Check if AMI creation failed
    if [[ "$current_state" == "failed" ]]; then
        log "${RED}Error: AMI creation failed${NC}"
        exit 1
    fi
    
    # Check if AMI is in pending state (expected)
    if [[ "$current_state" == "pending" ]]; then
        log "${YELLOW}AMI is still pending. Waiting $CHECK_INTERVAL seconds...${NC}"
    else
        log "${YELLOW}AMI is in state: $current_state. Waiting $CHECK_INTERVAL seconds...${NC}"
    fi
    
    # Check if maximum wait time exceeded
    if [[ $elapsed_time -ge $MAX_WAIT_TIME ]]; then
        log "${RED}Error: Maximum wait time ($MAX_WAIT_TIME seconds) exceeded${NC}"
        log "AMI is still in state: $current_state"
        exit 1
    fi
    
    # Wait before next check
    sleep $CHECK_INTERVAL
    elapsed_time=$((elapsed_time + CHECK_INTERVAL))
done

# Step 3: Create store image task
log "${GREEN}Executing: aws ec2 create-store-image-task --image-id $AMI_ID --bucket $BUCKET_NAME${NC}"
aws ec2 create-store-image-task --image-id $AMI_ID --bucket $BUCKET_NAME

if [ $? -eq 0 ]; then
    log "${GREEN}✓ AMI store task created successfully for bucket $BUCKET_NAME${NC}"
    
    # Optional: Create details file
    echo "AMI Details: ID=$AMI_ID, Name=$AMI_NAME, Date=$DATE" > ami_details_$DATE.txt
    log "AMI details saved to ami_details_$DATE.txt"
else
    log "${RED}Error creating AMI store task${NC}" >&2
    exit 1
fi

log "${GREEN}✓ Script completed successfully${NC}"
