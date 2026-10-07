#!/usr/bin/env python3
"""Tag, in the local clone only, every version the General registry has merged.

semantic-release takes the last release from the tags. TagBot pushes them once
General has merged a registration, but a tag can fail to appear: TagBot can
fail, and the tag of a deleted immutable GitHub release can never be created
again (as happened to v2.0.0). semantic-release would then compute the
registered version again, and General rejects it as already existing.

This makes General the source of truth instead: for each registered version
without a tag, it tags the commit whose tree is the registered one. The tags
are never pushed. A pending registration stays untagged, so a later run still
registers the same version again to update it.

Usage: tag-registered-versions.py
Run from the repository root with the full history fetched.
"""
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request

REGISTRY = "https://raw.githubusercontent.com/JuliaRegistries/General/master"


def git(*args):
    return subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    ).stdout


def registered_versions(name):
    url = f"{REGISTRY}/{name[0].upper()}/{name}/Versions.toml"
    try:
        with urllib.request.urlopen(url) as response:
            return tomllib.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return {}
        raise


def main():
    with open("Project.toml", "rb") as f:
        name = tomllib.load(f)["name"]
    tags = set(git("tag", "--list").split())
    # The oldest commit with a tree is the one that was registered.
    commits = {}
    for line in git("log", "--reverse", "--format=%T %H", "HEAD").splitlines():
        tree, commit = line.split()
        commits.setdefault(tree, commit)
    for version, entry in registered_versions(name).items():
        tag = f"v{version}"
        if tag in tags:
            continue
        commit = commits.get(entry["git-tree-sha1"])
        if commit is None:
            print(f"::warning::No commit has the tree of registered {version}")
            continue
        git("tag", tag, commit)
        print(f"Tagged registered {version} at {commit} locally", file=sys.stderr)


if __name__ == "__main__":
    main()
