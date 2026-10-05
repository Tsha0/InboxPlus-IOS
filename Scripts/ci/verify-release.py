#!/usr/bin/env python3
"""Require green main-branch CI for the exact source commit being released."""
import json, os, re, subprocess

def validate_version(value):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", value):
        raise ValueError("Use a numeric version such as 0.2.0")
    return value

def has_green_run(runs, sha):
    return any(r["head_sha"] == sha and r["event"] == "push" and r["head_branch"] == "main"
               and r["status"] == "completed" and r["conclusion"] == "success" for r in runs)

def main():
    version = validate_version(os.environ["RELEASE_VERSION"])
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    subprocess.run(["git", "merge-base", "--is-ancestor", sha, "origin/main"], check=True)
    repo = os.environ["GITHUB_REPOSITORY"]
    evidence = {}
    for workflow in ["ios-ci.yml", "companion-ci.yml"]:
        endpoint=f"repos/{repo}/actions/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100"
        runs=json.loads(subprocess.check_output(["gh", "api", endpoint]))["workflow_runs"]
        if not has_green_run(runs, sha):
            raise SystemExit(f"Release blocked: {workflow} has no successful main-branch push run for {sha}")
        evidence[workflow]=next(r["html_url"] for r in runs if has_green_run([r],sha))
    os.makedirs("build",exist_ok=True)
    with open("build/release-source.json","w") as f:
        json.dump({"commit":sha,"version":version,"run":os.environ.get("GITHUB_RUN_ID"),"checks":evidence},f,indent=2)
    print(f"Verified release {version} from {sha}")

if __name__ == "__main__": main()
