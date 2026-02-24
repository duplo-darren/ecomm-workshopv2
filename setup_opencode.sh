#!/bin/bash
#
# setup_opencode.sh
# Fully automates OpenCode installation, configuration, and AWS Bedrock model selection
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== OpenCode Setup Automation ===${NC}\n"

# Step 1: Install OpenCode
echo -e "${YELLOW}[1/4] Installing OpenCode...${NC}"
if command -v opencode &> /dev/null; then
    echo -e "${GREEN}✓ OpenCode is already installed${NC}"
else
    echo "Installing OpenCode via curl..."
    curl -fsSL https://opencode.ai/install | bash || {
        echo -e "${RED}✗ Failed to install OpenCode${NC}"
        exit 1
    }
    echo -e "${GREEN}✓ OpenCode installed successfully${NC}"
fi

# Step 2: Get AWS region
echo -e "\n${YELLOW}[2/4] Detecting AWS region...${NC}"
AWS_REGION=$(bash ~/ecomm-workshop/get_aws_region.sh)
echo -e "${GREEN}✓ AWS Region: $AWS_REGION${NC}"

# Step 3: Create global OpenCode config
echo -e "\n${YELLOW}[3/4] Configuring OpenCode...${NC}"

mkdir -p ~/.config/opencode

CONFIG_FILE="$HOME/.config/opencode/opencode.jsonc"

cat > "$CONFIG_FILE" << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "amazon-bedrock": {
      "options": {
        "region": "${AWS_REGION}",
        "profile": "default"
      }
    }
  },
  "model": "amazon-bedrock/us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  "small_model": "amazon-bedrock/us.anthropic.claude-haiku-4-5-20251001-v1:0",
  "theme": "opencode",
  "autoupdate": true
}
EOF

echo -e "${GREEN}✓ Config file created at: $CONFIG_FILE${NC}"

# Step 4: Update environment variables
echo -e "\n${YELLOW}[4/4] Setting up environment variables...${NC}"

# Check if variables are already in bashrc
if grep -q "AWS_REGION" ~/.bashrc; then
    echo -e "${YELLOW}⚠ AWS_REGION already set in ~/.bashrc${NC}"
else
    echo "export AWS_REGION=\$(bash ~/ecomm-workshop/get_aws_region.sh)" >> ~/.bashrc
    echo -e "${GREEN}✓ Added AWS_REGION to ~/.bashrc${NC}"
fi

# Make the config file use environment variable substitution
# Replace the hardcoded placeholder with actual region in the config
sed -i "s/\${AWS_REGION}/$AWS_REGION/g" "$CONFIG_FILE"

# Configure AWS CLI with the detected region
echo -e "\n${YELLOW}[4b/4] Configuring AWS CLI...${NC}"

mkdir -p ~/.aws

# Create or update AWS config file with region (no credentials, inherited from instance)
if [ -f ~/.aws/config ]; then
    # Check if default profile exists
    if grep -q "\[default\]" ~/.aws/config; then
        # Update existing default profile
        if grep -q "region" ~/.aws/config; then
            sed -i "s/^region =.*/region = $AWS_REGION/" ~/.aws/config
        else
            sed -i "/\[default\]/a region = $AWS_REGION" ~/.aws/config
        fi
    else
        # Add default profile if it doesn't exist
        echo -e "\n[default]\nregion = $AWS_REGION" >> ~/.aws/config
    fi
else
    # Create new config file
    cat > ~/.aws/config << AWSCONFIG
[default]
region = $AWS_REGION
AWSCONFIG
fi

echo -e "${GREEN}✓ AWS CLI configured with region: $AWS_REGION${NC}"
echo -e "${GREEN}✓ Credentials inherited from EC2 instance${NC}"

echo -e "\n${GREEN}=== Setup Complete ===${NC}\n"
echo -e "Next steps:"
echo -e "1. Ensure you have AWS credentials configured:"
echo -e "   ${YELLOW}aws configure${NC} (or use AWS SSO if available)"
echo -e ""
echo -e "2. Start OpenCode in your project directory:"
echo -e "   ${YELLOW}cd /path/to/project && opencode${NC}"
echo -e ""
echo -e "3. Select a Bedrock model:"
echo -e "   ${YELLOW}/models${NC}"
echo -e ""
echo -e "4. Initialize for your project:"
echo -e "   ${YELLOW}/init${NC}"
echo -e ""
echo -e "Configuration file: $CONFIG_FILE"
echo -e "Region detected: $AWS_REGION"
echo ""

