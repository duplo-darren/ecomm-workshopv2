#!/usr/bin/env python3
"""
Monolith Repository Analysis Script
Produces a structured inventory of all repos being analyzed.

Usage:
  python3 scripts/analysis/repo_analysis.py <repos-directory> > docs/architecture/01-repo-inventory.md
"""

import os
import sys
import subprocess
import json
from pathlib import Path
from collections import defaultdict


def run(cmd, cwd=None):
    """Run a shell command and return stdout."""
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True, cwd=cwd
    )
    return result.stdout.strip()


def count_lines(repo_path):
    """Use cloc if available, otherwise fall back to wc -l."""
    cloc_out = run(
        "cloc --json --exclude-dir=node_modules,vendor,.git,dist,build .",
        cwd=repo_path
    )
    if cloc_out and cloc_out.startswith('{'):
        try:
            data = json.loads(cloc_out)
            return {
                lang: {
                    "files": info["nFiles"],
                    "blank": info["blank"],
                    "comment": info["comment"],
                    "code": info["code"]
                }
                for lang, info in data.items()
                if lang not in ("header", "SUM")
            }
        except (json.JSONDecodeError, KeyError):
            pass
    # fallback
    total = run("find . -type f -name '*.py' -o -name '*.js' -o -name '*.ts' "
                "-o -name '*.java' -o -name '*.go' -o -name '*.rb' | "
                "xargs wc -l 2>/dev/null | tail -1", cwd=repo_path)
    return {"unknown": {"code": total.split()[0] if total else "unknown"}}


def find_routes(repo_path):
    """Find API route definitions across common frameworks."""
    routes = []
    patterns = [
        # Express
        ("grep", "-rn", r"app\.\(get\|post\|put\|patch\|delete\)\|router\.\(get\|post\|put\|patch\|delete\)",
         "--include=*.js", "--include=*.ts"),
        # Django
        ("grep", "-rn", r"path\|url\|re_path", "--include=urls.py"),
        # Spring
        ("grep", "-rn", r"@GetMapping\|@PostMapping\|@PutMapping\|@DeleteMapping\|@RequestMapping",
         "--include=*.java"),
        # FastAPI/Flask
        ("grep", "-rn", r"@app\.route\|@router\.", "--include=*.py"),
        # Go
        ("grep", "-rn", r"\.GET\|\.POST\|\.PUT\|\.DELETE\|\.Handle\b\|\.HandleFunc\b",
         "--include=*.go"),
    ]
    for pattern in patterns:
        cmd = f"grep -rn '{pattern[2]}' . {pattern[3] if len(pattern) > 3 else ''} 2>/dev/null | head -50"
        output = run(cmd, cwd=repo_path)
        if output:
            routes.extend(output.split('\n')[:10])  # cap per pattern
    return routes[:50]


def find_db_models(repo_path):
    """Find database model/entity definitions."""
    results = []
    checks = [
        ("Python ORM", "grep -rn 'class.*Model\\|class.*Base\\|Column(' . --include='*.py' 2>/dev/null | head -20"),
        ("TypeORM", "find . -name '*.entity.ts' 2>/dev/null | head -10"),
        ("Prisma", "find . -name 'schema.prisma' 2>/dev/null"),
        ("JPA Entities", "grep -rn '@Entity\\|@Table' . --include='*.java' 2>/dev/null | head -20"),
        ("Rails Models", "find . -path '*/app/models/*.rb' 2>/dev/null | head -10"),
        ("GORM", "grep -rn 'gorm.Model\\|gorm:' . --include='*.go' 2>/dev/null | head -20"),
        ("Migrations", "find . -type d -name 'migrations' 2>/dev/null"),
    ]
    for label, cmd in checks:
        output = run(cmd, cwd=repo_path)
        if output:
            results.append((label, output))
    return results


def find_external_deps(repo_path):
    """Find external service dependencies."""
    patterns = {
        "AWS SDK": "grep -rn 'boto3\\|aws-sdk\\|@aws-sdk\\|amazonaws' . --include='*.py' --include='*.js' --include='*.ts' --include='*.java' --include='*.go' 2>/dev/null | grep -v node_modules | wc -l",
        "HTTP Clients": "grep -rn 'requests\\|axios\\|fetch\\|http.get\\|RestTemplate\\|http.NewRequest' . --include='*.py' --include='*.js' --include='*.ts' --include='*.java' --include='*.go' 2>/dev/null | grep -v node_modules | wc -l",
        "Message Queues": "grep -rn 'SQS\\|SNS\\|kafka\\|rabbitmq\\|celery\\|bull\\|sidekiq' . --include='*.py' --include='*.js' --include='*.ts' --include='*.java' 2>/dev/null | grep -v node_modules | wc -l",
        "Redis/Cache": "grep -rn 'redis\\|memcache\\|elasticache' . 2>/dev/null | grep -v node_modules | wc -l",
        "S3/Storage": "grep -rn 's3\\|boto3.client\\|S3Client\\|storage.bucket' . 2>/dev/null | grep -v node_modules | wc -l",
    }
    results = {}
    for name, cmd in patterns.items():
        count = run(cmd, cwd=repo_path)
        try:
            results[name] = int(count.strip())
        except ValueError:
            results[name] = 0
    return results


def find_config_files(repo_path):
    """Find configuration and environment files."""
    cmd = "find . -name '*.env*' -o -name 'docker-compose*.yml' -o -name 'Dockerfile' -o -name '*.env.example' 2>/dev/null | grep -v '.git' | grep -v node_modules | sort"
    return run(cmd, cwd=repo_path)


def analyze_repo(repo_path):
    """Analyze a single repository."""
    path = Path(repo_path)
    name = path.name

    print(f"\n## Repository: `{name}`\n")
    print(f"**Path**: `{repo_path}`\n")

    # Git info
    last_commit = run("git log -1 --format='%h %ad %s' --date=short", cwd=repo_path)
    total_commits = run("git rev-list --count HEAD 2>/dev/null", cwd=repo_path)
    print(f"**Last commit**: {last_commit}")
    print(f"**Total commits**: {total_commits}\n")

    # Language breakdown
    print("### Language Breakdown\n")
    loc = count_lines(repo_path)
    if isinstance(loc, dict):
        for lang, stats in sorted(loc.items(), key=lambda x: x[1].get("code", 0) if isinstance(x[1], dict) else 0, reverse=True):
            if isinstance(stats, dict):
                print(f"- **{lang}**: {stats.get('code', '?')} lines of code ({stats.get('files', '?')} files)")
    print()

    # Directory structure
    print("### Directory Structure\n")
    tree_out = run("tree -L 2 -I 'node_modules|vendor|.git|*.pyc|__pycache__|dist|build' --dirsfirst . 2>/dev/null || find . -maxdepth 2 -type d | grep -v .git | grep -v node_modules | sort", cwd=repo_path)
    print("```")
    print(tree_out[:2000])  # cap output
    print("```\n")

    # Config files
    print("### Configuration Files\n")
    configs = find_config_files(repo_path)
    if configs:
        for f in configs.split('\n')[:20]:
            print(f"- `{f}`")
    print()

    # API routes sample
    print("### API Routes (sample)\n")
    routes = find_routes(repo_path)
    if routes:
        print("```")
        for r in routes[:20]:
            print(r)
        print("```")
    else:
        print("_No route patterns detected automatically — review manually._")
    print()

    # DB models
    print("### Database Models\n")
    models = find_db_models(repo_path)
    if models:
        for label, output in models:
            print(f"**{label}**:")
            print("```")
            print(output[:500])
            print("```")
    else:
        print("_No ORM models detected automatically — review manually._")
    print()

    # External deps
    print("### External Service References (occurrence count)\n")
    deps = find_external_deps(repo_path)
    for dep, count in deps.items():
        indicator = "✓" if count > 0 else "·"
        print(f"- {indicator} **{dep}**: {count} references")
    print()


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 repo_analysis.py <repos-directory>")
        sys.exit(1)

    repos_dir = Path(sys.argv[1])

    print("# Repository Inventory\n")
    print(f"_Generated by repo_analysis.py_\n")
    print("---\n")

    repos = [d for d in sorted(repos_dir.iterdir()) if d.is_dir() and not d.name.startswith('.')]

    print(f"**Total repositories found**: {len(repos)}\n")
    print("| Repository | Language | Est. LOC |")
    print("|------------|----------|----------|")
    for repo in repos:
        loc = count_lines(str(repo))
        total_code = sum(
            v.get("code", 0) if isinstance(v, dict) else 0
            for v in loc.values()
        ) if isinstance(loc, dict) else "?"
        lang = ", ".join(list(loc.keys())[:3]) if isinstance(loc, dict) else "?"
        print(f"| {repo.name} | {lang} | {total_code} |")

    print()
    print("---\n")
    print("## Detailed Analysis\n")

    for repo in repos:
        analyze_repo(str(repo))
        print("\n---\n")


if __name__ == "__main__":
    main()
