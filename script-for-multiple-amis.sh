#!/bin/bash

# Multi-AMI Backup Script
# This script creates AMIs for multiple EC2 instances and stores them in S3

# Configuration
INSTANCE_IDS=(
    "i-04452c50049ed431c"  # Replace with your instance IDs
    "i-0123456789abcdef0"
    "i-0fedcba9876543210"
)
BUCKET_NAME="venkatbyte"  # Replace with your S3 bucket name
DATE=$(date +%F-%H-%M-%S)
CHECK_INTERVAL=30  # Check every 30 seconds
MAX_WAIT_TIME=600  # Maximum wait time in seconds (10 minutes)
PARALLEL_PROCESSING=false  # Set to true for parallel processing, false for sequential

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Arrays to track AMI processing
declare -A AMI_IDS
declare -A AMI_NAMES
declare -A AMI_STATES
declare -A INSTANCE_NAMES

# Logging function
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Function to get instance name
get_instance_name() {
    local instance_id=$1
    aws ec2 describe-instances --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].Tags[?Key==`Name`].Value' \
        --output text 2>/dev/null | head -1
}

# Function to check AMI state
check_ami_state() {
    local ami_id=$1
    aws ec2 describe-images --image-ids "$ami_id" --query 'Images[0].State' --output text 2>/dev/null
}

# Function to create AMI for a single instance
create_ami() {
    local instance_id=$1
    local instance_name=${INSTANCE_NAMES[$instance_id]}
    local ami_name="Backup-${instance_name:-$instance_id}-$DATE"
    
    log "${BLUE}Creating AMI for instance $instance_id ($instance_name)...${NC}"
    
    local ami_id=$(aws ec2 create-image \
        --instance-id "$instance_id" \
        --name "$ami_name" \
        --description "Backup of $instance_id on $DATE" \
        --no-reboot \
        --output text \
        --query 'ImageId' 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$ami_id" ]; then
        AMI_IDS[$instance_id]=$ami_id
        AMI_NAMES[$instance_id]=$ami_name
        AMI_STATES[$instance_id]="pending"
        log "${GREEN}✓ AMI $ami_id created for instance $instance_id with name $ami_name${NC}"
        return 0
    else
        log "${RED}✗ Error creating AMI for instance $instance_id${NC}"
        return 1
    fi
}

# Function to monitor AMI creation for a single instance
monitor_ami() {
    local instance_id=$1
    local ami_id=${AMI_IDS[$instance_id]}
    local instance_name=${INSTANCE_NAMES[$instance_id]}
    local elapsed_time=0
    local checks_performed=0
    
    log "${BLUE}Monitoring AMI creation for instance $instance_id ($instance_name)...${NC}"
    
    while true; do
        checks_performed=$((checks_performed + 1))
        
        # Get current AMI state
        local current_state=$(check_ami_state "$ami_id")
        
        # Handle empty response (API error)
        if [[ -z "$current_state" ]]; then
            log "${RED}✗ Error: Unable to retrieve AMI state for $ami_id${NC}"
            AMI_STATES[$instance_id]="error"
            return 1
        fi
        
        # Update state
        AMI_STATES[$instance_id]=$current_state
        
        # Check if AMI is available
        if [[ "$current_state" == "available" ]]; then
            log "${GREEN}✓ AMI $ami_id is now available for instance $instance_id${NC}"
            return 0
        fi
        
        # Check if AMI creation failed
        if [[ "$current_state" == "failed" ]]; then
            log "${RED}✗ AMI creation failed for instance $instance_id${NC}"
            AMI_STATES[$instance_id]="failed"
            return 1
        fi
        
        # Check if AMI is in pending state (expected)
        if [[ "$current_state" == "pending" ]]; then
            log "${YELLOW}AMI $ami_id is still pending for instance $instance_id. Check #$checks_performed${NC}"
        else
            log "${YELLOW}AMI $ami_id is in state: $current_state for instance $instance_id${NC}"
        fi
        
        # Check if maximum wait time exceeded
        if [[ $elapsed_time -ge $MAX_WAIT_TIME ]]; then
            log "${RED}✗ Maximum wait time ($MAX_WAIT_TIME seconds) exceeded for instance $instance_id${NC}"
            AMI_STATES[$instance_id]="timeout"
            return 1
        fi
        
        # Wait before next check
        sleep $CHECK_INTERVAL
        elapsed_time=$((elapsed_time + CHECK_INTERVAL))
    done
}

# Function to create store image task
create_store_task() {
    local instance_id=$1
    local ami_id=${AMI_IDS[$instance_id]}
    local instance_name=${INSTANCE_NAMES[$instance_id]}
    
    log "${BLUE}Creating store image task for AMI $ami_id (instance $instance_id)...${NC}"
    
    aws ec2 create-store-image-task --image-id "$ami_id" --bucket "$BUCKET_NAME"
    
    if [ $? -eq 0 ]; then
        log "${GREEN}✓ AMI store task created successfully for $ami_id${NC}"
        return 0
    else
        log "${RED}✗ Error creating AMI store task for $ami_id${NC}"
        return 1
    fi
}

# Function to process single instance (create AMI, monitor, and store)
process_instance() {
    local instance_id=$1
    
    # Create AMI
    if ! create_ami "$instance_id"; then
        return 1
    fi
    
    # Monitor AMI creation
    if ! monitor_ami "$instance_id"; then
        return 1
    fi
    
    # Create store task
    if ! create_store_task "$instance_id"; then
        return 1
    fi
    
    return 0
}

# Function to monitor all AMIs simultaneously
monitor_all_amis() {
    local all_complete=false
    local total_elapsed=0
    
    log "${BLUE}Monitoring all AMI creations simultaneously...${NC}"
    
    while [[ "$all_complete" == false ]] && [[ $total_elapsed -lt $MAX_WAIT_TIME ]]; do
        all_complete=true
        
        for instance_id in "${INSTANCE_IDS[@]}"; do
            # Skip if AMI creation failed for this instance
            if [[ -z "${AMI_IDS[$instance_id]}" ]]; then
                continue
            fi
            
            local ami_id=${AMI_IDS[$instance_id]}
            local current_state=$(check_ami_state "$ami_id")
            
            if [[ -z "$current_state" ]]; then
                log "${RED}✗ Error retrieving state for AMI $ami_id${NC}"
                AMI_STATES[$instance_id]="error"
                continue
            fi
            
            AMI_STATES[$instance_id]=$current_state
            
            if [[ "$current_state" == "pending" ]]; then
                all_complete=false
            elif [[ "$current_state" == "failed" ]]; then
                log "${RED}✗ AMI creation failed for instance $instance_id${NC}"
            elif [[ "$current_state" == "available" ]]; then
                log "${GREEN}✓ AMI $ami_id is available for instance $instance_id${NC}"
            fi
        done
        
        if [[ "$all_complete" == false ]]; then
            sleep $CHECK_INTERVAL
            total_elapsed=$((total_elapsed + CHECK_INTERVAL))
            log "${YELLOW}Waiting for AMIs to complete... ($total_elapsed/${MAX_WAIT_TIME}s)${NC}"
        fi
    done
    
    if [[ $total_elapsed -ge $MAX_WAIT_TIME ]]; then
        log "${RED}✗ Maximum wait time exceeded for AMI monitoring${NC}"
        return 1
    fi
    
    return 0
}

# Main execution starts here
log "${GREEN}Starting Multi-AMI Backup Script${NC}"
log "Processing ${#INSTANCE_IDS[@]} instances"
log "Bucket: $BUCKET_NAME"
log "Date: $DATE"
log "Parallel Processing: $PARALLEL_PROCESSING"

# Get instance names
for instance_id in "${INSTANCE_IDS[@]}"; do
    instance_name=$(get_instance_name "$instance_id")
    INSTANCE_NAMES[$instance_id]=${instance_name:-"Unknown"}
    log "Instance $instance_id: ${INSTANCE_NAMES[$instance_id]}"
done

# Create AMIs for all instances
log "${BLUE}Step 1: Creating AMIs for all instances...${NC}"
failed_instances=()
for instance_id in "${INSTANCE_IDS[@]}"; do
    if ! create_ami "$instance_id"; then
        failed_instances+=("$instance_id")
    fi
done

# Check if any AMIs were created successfully
successful_instances=()
for instance_id in "${INSTANCE_IDS[@]}"; do
    if [[ -n "${AMI_IDS[$instance_id]}" ]]; then
        successful_instances+=("$instance_id")
    fi
done

if [[ ${#successful_instances[@]} -eq 0 ]]; then
    log "${RED}✗ No AMIs were created successfully. Exiting.${NC}"
    exit 1
fi

log "${GREEN}Successfully created ${#successful_instances[@]} AMIs${NC}"

# Monitor AMI creation
log "${BLUE}Step 2: Monitoring AMI creation...${NC}"
if [[ "$PARALLEL_PROCESSING" == true ]]; then
    # Monitor all AMIs simultaneously
    monitor_all_amis
else
    # Monitor AMIs sequentially
    for instance_id in "${successful_instances[@]}"; do
        monitor_ami "$instance_id"
    done
fi

# Create store tasks for available AMIs
log "${BLUE}Step 3: Creating store image tasks...${NC}"
successful_stores=0
for instance_id in "${successful_instances[@]}"; do
    if [[ "${AMI_STATES[$instance_id]}" == "available" ]]; then
        if create_store_task "$instance_id"; then
            successful_stores=$((successful_stores + 1))
        fi
    else
        log "${YELLOW}Skipping store task for instance $instance_id (AMI state: ${AMI_STATES[$instance_id]})${NC}"
    fi
done

# Generate summary report
log "${BLUE}Generating summary report...${NC}"
summary_file="ami_backup_summary_$DATE.txt"
cat > "$summary_file" << EOF
AMI Backup Summary Report
Date: $DATE
Bucket: $BUCKET_NAME
Total Instances Processed: ${#INSTANCE_IDS[@]}
Successful AMI Creations: ${#successful_instances[@]}
Successful Store Tasks: $successful_stores

Instance Details:
EOF

for instance_id in "${INSTANCE_IDS[@]}"; do
    instance_name=${INSTANCE_NAMES[$instance_id]}
    ami_id=${AMI_IDS[$instance_id]:-"N/A"}
    ami_name=${AMI_NAMES[$instance_id]:-"N/A"}
    ami_state=${AMI_STATES[$instance_id]:-"Failed to create"}
    
    cat >> "$summary_file" << EOF
  Instance ID: $instance_id
  Instance Name: $instance_name
  AMI ID: $ami_id
  AMI Name: $ami_name
  AMI State: $ami_state
  ---
EOF
done

log "${GREEN}Summary report saved to $summary_file${NC}"

# Final status
if [[ ${#failed_instances[@]} -gt 0 ]]; then
    log "${YELLOW}Script completed with some failures:${NC}"
    log "${RED}Failed instances: ${failed_instances[*]}${NC}"
    exit 1
else
    log "${GREEN}✓ Script completed successfully for all instances${NC}"
    exit 0
fi
