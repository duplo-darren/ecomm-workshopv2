#!/bin/bash
# =============================================================================
# Temporary Migration Resource Tracker
#
# Migration requires temporary AWS resources (bastion hosts, migration IAM roles,
# data transfer tools, cross-account access, etc.) that MUST be removed after
# migration completes to maintain least-privilege posture.
#
# This script tracks those resources in a manifest and provides commands to
# remove them when the migration phase is complete.
#
# Usage:
#   bash scripts/temp_resources_tracker.sh register <type> <id> <reason> <phase>
#   bash scripts/temp_resources_tracker.sh list
#   bash scripts/temp_resources_tracker.sh cleanup <phase>
#   bash scripts/temp_resources_tracker.sh cleanup-all
#
# Examples:
#   bash scripts/temp_resources_tracker.sh register "aws_iam_role" \
#     "arn:aws:iam::123456789:role/migration-data-role" \
#     "Allows EKS pod to read from legacy RDS" "phase-5-migration"
#
#   bash scripts/temp_resources_tracker.sh register "aws_security_group" \
#     "sg-0abc123" "Bastion access to legacy DB" "phase-5-migration"
#
#   bash scripts/temp_resources_tracker.sh cleanup phase-5-migration
# =============================================================================

set -euo pipefail

MANIFEST_FILE="docs/migration/temp-resources-manifest.json"
TERRAFORM_TEMP_FILE="terraform/temp-migration-resources.tf"

# Ensure manifest directory exists
mkdir -p "$(dirname "$MANIFEST_FILE")"

# Initialize manifest if it doesn't exist
if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo '{"temp_resources": [], "cleanup_log": []}' > "$MANIFEST_FILE"
  echo "Initialized temp resources manifest at $MANIFEST_FILE"
fi

ACTION="${1:-list}"

# =============================================================================
case "$ACTION" in
# =============================================================================

register)
  RESOURCE_TYPE="${2:?Usage: register <type> <id> <reason> <phase>}"
  RESOURCE_ID="${3:?Missing resource ID}"
  REASON="${4:?Missing reason}"
  PHASE="${5:?Missing phase (e.g., phase-5-migration)}"
  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  NEW_ENTRY=$(cat << EOF
{
  "type": "$RESOURCE_TYPE",
  "id": "$RESOURCE_ID",
  "reason": "$REASON",
  "phase": "$PHASE",
  "registered_at": "$TIMESTAMP",
  "status": "active"
}
EOF
)

  # Add to manifest using Python (more reliable than pure bash JSON manipulation)
  python3 - << PYEOF
import json

with open("$MANIFEST_FILE") as f:
    manifest = json.load(f)

entry = $NEW_ENTRY
manifest["temp_resources"].append(entry)

with open("$MANIFEST_FILE", "w") as f:
    json.dump(manifest, f, indent=2)

print(f"✓ Registered: {entry['type']} / {entry['id']}")
print(f"  Reason: {entry['reason']}")
print(f"  Phase: {entry['phase']}")
print(f"  Will be cleaned up when: bash scripts/temp_resources_tracker.sh cleanup {entry['phase']}")
PYEOF

  # Append to Terraform temp file as a comment reference
  cat >> "$TERRAFORM_TEMP_FILE.notes" << EOF
# TEMP RESOURCE: $RESOURCE_TYPE
# ID: $RESOURCE_ID
# Reason: $REASON
# Phase: $PHASE
# Registered: $TIMESTAMP
# Status: ACTIVE — must be removed at end of $PHASE
EOF

  # Commit the registration
  git add "$MANIFEST_FILE" 2>/dev/null || true
  git diff --cached --quiet || \
    git commit -m "chore(migration): register temp resource $RESOURCE_TYPE for $PHASE — $REASON" 2>/dev/null || true
  ;;

# =============================================================================
list)
  echo ""
  echo "=== ACTIVE TEMPORARY MIGRATION RESOURCES ==="
  echo "(These MUST be removed before declaring migration complete)"
  echo ""

  python3 - << 'PYEOF'
import json

with open("docs/migration/temp-resources-manifest.json") as f:
    manifest = json.load(f)

active = [r for r in manifest["temp_resources"] if r["status"] == "active"]

if not active:
    print("✓ No active temporary resources. Clean!")
else:
    by_phase = {}
    for r in active:
        by_phase.setdefault(r["phase"], []).append(r)

    for phase, resources in sorted(by_phase.items()):
        print(f"\n  Phase: {phase}")
        print(f"  {'─' * 50}")
        for r in resources:
            print(f"  ⚠  [{r['type']}] {r['id']}")
            print(f"     Reason: {r['reason']}")
            print(f"     Registered: {r['registered_at']}")
        print()

    print(f"Total active temp resources: {len(active)}")
    print("\nTo remove by phase:")
    for phase in sorted(by_phase.keys()):
        print(f"  bash scripts/temp_resources_tracker.sh cleanup {phase}")
PYEOF
  ;;

# =============================================================================
cleanup)
  PHASE="${2:?Usage: cleanup <phase>}"
  echo ""
  echo "=== CLEANING UP TEMPORARY RESOURCES: $PHASE ==="
  echo ""

  python3 - << PYEOF
import json
import subprocess

PHASE = "$PHASE"

with open("$MANIFEST_FILE") as f:
    manifest = json.load(f)

to_cleanup = [r for r in manifest["temp_resources"]
              if r["phase"] == PHASE and r["status"] == "active"]

if not to_cleanup:
    print(f"No active resources in phase {PHASE}")
    exit(0)

print(f"Found {len(to_cleanup)} resource(s) to clean up:")
for r in to_cleanup:
    print(f"  - [{r['type']}] {r['id']}")

print("")
print("REVIEW: The following cleanup commands will be run.")
print("ALWAYS review before executing in production.")
print("─" * 60)

for r in to_cleanup:
    rtype = r["type"]
    rid = r["id"]

    if rtype == "aws_iam_role":
        print(f"# Remove inline policies and detach managed policies, then:")
        print(f"aws iam list-role-policies --role-name \$(echo '{rid}' | awk -F'/' '{{print \$NF}}')")
        print(f"aws iam delete-role --role-name \$(echo '{rid}' | awk -F'/' '{{print \$NF}}')")
    elif rtype == "aws_iam_policy":
        print(f"aws iam delete-policy --policy-arn '{rid}'")
    elif rtype == "aws_security_group":
        print(f"aws ec2 delete-security-group --group-id '{rid}'")
    elif rtype == "aws_instance":
        print(f"aws ec2 terminate-instances --instance-ids '{rid}'")
    elif rtype == "aws_iam_user":
        print(f"# Delete access keys first:")
        print(f"aws iam list-access-keys --user-name '{rid}'")
        print(f"aws iam delete-user --user-name '{rid}'")
    elif rtype == "aws_vpc_peering_connection":
        print(f"aws ec2 delete-vpc-peering-connection --vpc-peering-connection-id '{rid}'")
    elif rtype == "terraform_resource":
        print(f"# Remove from Terraform:")
        print(f"terraform destroy -target='{rid}'")
    else:
        print(f"# Manual cleanup required for {rtype}:")
        print(f"# Resource ID: {rid}")
        print(f"# Reason it existed: {r['reason']}")

print("")
print("─" * 60)
response = input("Execute cleanup? (type 'yes' to confirm): ")

if response.strip().lower() != "yes":
    print("Aborted. Run the commands manually or re-run this script.")
    exit(0)

# Execute cleanup
from datetime import datetime

for r in to_cleanup:
    rtype = r["type"]
    rid = r["id"]
    print(f"\nCleaning up: [{rtype}] {rid}")

    cmd = None
    if rtype == "aws_iam_policy":
        cmd = f"aws iam delete-policy --policy-arn '{rid}'"
    elif rtype == "aws_security_group":
        cmd = f"aws ec2 delete-security-group --group-id '{rid}'"
    elif rtype == "aws_instance":
        cmd = f"aws ec2 terminate-instances --instance-ids '{rid}'"
    elif rtype == "terraform_resource":
        cmd = f"cd terraform/environments/\$ENV && terraform destroy -target='{rid}' -auto-approve"

    if cmd:
        result = subprocess.run(cmd, shell=True)
        if result.returncode == 0:
            r["status"] = "cleaned_up"
            r["cleaned_up_at"] = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
            manifest["cleanup_log"].append({
                "resource": r,
                "cleaned_at": r["cleaned_up_at"],
                "command": cmd
            })
            print(f"  ✓ Done")
        else:
            print(f"  ✗ FAILED — please clean up manually")
    else:
        print(f"  ⚠ Manual cleanup required for {rtype}")
        print(f"  Mark as done manually when complete.")
        confirm = input(f"  Mark [{rtype}] {rid} as cleaned? (y/N): ")
        if confirm.lower() == "y":
            r["status"] = "cleaned_up"
            r["cleaned_up_at"] = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

with open("$MANIFEST_FILE", "w") as f:
    json.dump(manifest, f, indent=2)

remaining = [r for r in manifest["temp_resources"] if r["status"] == "active"]
print(f"\n✓ Cleanup complete for phase {PHASE}")
print(f"Remaining active temp resources: {len(remaining)}")
PYEOF

  git add "$MANIFEST_FILE"
  git commit -m "chore(security): clean up temp migration resources for $PHASE — least-privilege posture restored"
  ;;

# =============================================================================
cleanup-all)
  echo "Cleaning up ALL active temporary resources..."
  python3 - << 'PYEOF'
import json

with open("docs/migration/temp-resources-manifest.json") as f:
    manifest = json.load(f)

phases = list(set(r["phase"] for r in manifest["temp_resources"] if r["status"] == "active"))
if not phases:
    print("✓ No active temp resources to clean up.")
else:
    print(f"Phases to clean: {', '.join(sorted(phases))}")
    for phase in sorted(phases):
        import subprocess
        subprocess.run(
            ["bash", "scripts/temp_resources_tracker.sh", "cleanup", phase]
        )
PYEOF
  ;;

# =============================================================================
*)
  echo "Usage: $0 {register|list|cleanup|cleanup-all}"
  echo ""
  echo "  register <type> <id> <reason> <phase>  — Track a temp resource"
  echo "  list                                    — Show active temp resources"
  echo "  cleanup <phase>                         — Remove resources for a phase"
  echo "  cleanup-all                             — Remove all temp resources"
  exit 1
  ;;
esac
