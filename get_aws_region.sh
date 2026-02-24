#!/bin/bash
#
# get_aws_region.sh
# Automatically identifies the AWS region of the current EC2 instance
#

set -e

# Method 1: Try EC2 instance metadata service (IMDSv2)
get_region_from_metadata() {
    # Get IMDSv2 token
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        -s --connect-timeout 2 2>/dev/null || echo "")
    
    if [ -n "$TOKEN" ]; then
        # Use token to get region
        REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
            -s --connect-timeout 2 \
            http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
        echo "$REGION"
    else
        # Fallback to IMDSv1
        REGION=$(curl -s --connect-timeout 2 \
            http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
        echo "$REGION"
    fi
}

# Method 2: Try AWS CLI default region
get_region_from_cli() {
    aws configure get region 2>/dev/null || echo ""
}

# Method 3: Try availability zone and extract region
get_region_from_az() {
    TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
        -s --connect-timeout 2 2>/dev/null || echo "")
    
    if [ -n "$TOKEN" ]; then
        AZ=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" \
            -s --connect-timeout 2 \
            http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "")
    else
        AZ=$(curl -s --connect-timeout 2 \
            http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || echo "")
    fi
    
    if [ -n "$AZ" ]; then
        # Extract region from AZ (remove last character, e.g., us-east-1a -> us-east-1)
        echo "${AZ%?}"
    fi
}

# Try methods in order
REGION=$(get_region_from_metadata)

if [ -z "$REGION" ]; then
    REGION=$(get_region_from_az)
fi

if [ -z "$REGION" ]; then
    REGION=$(get_region_from_cli)
fi

# Output result
if [ -n "$REGION" ]; then
    echo "$REGION"
    exit 0
else
    echo "ERROR: Could not determine AWS region" >&2
    exit 1
fi

