"""Build and push Docker images for each microservice to ECR.

Usage:
    python build_and_push.py
"""

import base64
import json
import os
import subprocess
import sys

import boto3

SERVICES = ["catalog", "inventory", "frontend"]
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def get_account_id():
    sts = boto3.client("sts")
    return sts.get_caller_identity()["Account"]


def ecr_login(region, registry):
    ecr = boto3.client("ecr", region_name=region)
    token_response = ecr.get_authorization_token()
    auth = token_response["authorizationData"][0]
    token = base64.b64decode(auth["authorizationToken"]).decode()
    username, password = token.split(":", 1)
    subprocess.run(
        ["docker", "login", "--username", username, "--password-stdin", registry],
        input=password.encode(),
        check=True,
    )


def build_and_push(service, registry, repo_prefix, tag):
    build_context = os.path.join(SCRIPT_DIR, "microservices", service)
    repo = f"{repo_prefix}-{service}"
    image_tag = f"{registry}/{repo}:{tag}"

    print(f"\n--- {service} ---")
    print(f"Building {image_tag} ...")
    subprocess.run(
        ["docker", "build", "-t", image_tag, build_context],
        check=True,
    )

    print(f"Pushing {image_tag} ...")
    subprocess.run(["docker", "push", image_tag], check=True)
    print(f"Done: {image_tag}")


def main():
    repo_prefix = input("Please enter your tenant_name: ").strip()
    if not repo_prefix:
        print("No prefix provided, aborting.")
        sys.exit(1)

    tag = input("Image tag (e.g. v1.0.0): ").strip()
    if not tag:
        print("No tag provided, aborting.")
        sys.exit(1)

    region = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "us-east-1"))

    print("Retrieving AWS account ID via STS...")
    account_id = get_account_id()
    registry = f"{account_id}.dkr.ecr.{region}.amazonaws.com"
    print(f"Registry: {registry}")

    print("Logging in to ECR...")
    ecr_login(region, registry)

    for service in SERVICES:
        build_and_push(service, registry, repo_prefix, tag)

    print("\nAll images pushed successfully.")


if __name__ == "__main__":
    main()
