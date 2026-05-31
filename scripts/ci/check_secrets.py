#!/usr/bin/env python3
"""Pre-commit check: ban API keys and secrets in committed code.

Known patterns:
  - Anthropic:   sk-ant-api03-..., sk-ant-admin01-...
  - OpenAI:      sk-..., sk-proj-... (51+ chars)
  - Google:      AIza... (39 chars)
  - ElevenLabs:  32-char hex
  - GitHub:      ghp_..., gho_..., ghu_..., ghs_..., ghr_...
  - Generic:     BEGIN PRIVATE KEY, BEGIN RSA PRIVATE KEY, ssh-rsa

Usage:
    python3 scripts/ci/check_secrets.py [file1] [file2] ...
    # No args = scan staged files

Exit code 1 if any secret found.
"""

import os
import re
import subprocess
import sys
from pathlib import Path


# (label, regex, min_length_to_flag)
PATTERNS = [
    ("anthropic", re.compile(r"sk-ant-(?:api|admin)[0-9]{2}-[A-Za-z0-9_-]{90,}"), 90),
    ("openai",    re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{40,}"), 40),
    ("google",    re.compile(r"AIza[0-9A-Za-z_-]{35}"), 35),
    ("elevenlabs",re.compile(r"\b[a-f0-9]{32}\b"), 32),
    ("gh-token",  re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}"), 36),
    ("aws-akid",  re.compile(r"AKIA[0-9A-Z]{16}"), 16),
    ("slack",     re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"), 10),
    ("private-key-header", re.compile(r"-----BEGIN (?:RSA |EC |DSA |OPENSSH )?PRIVATE KEY-----"), 0),
    ("gmail-app-password", re.compile(r"\b[a-z]{4} [a-z]{4} [a-z]{4} [a-z]{4}\b"), 0),
]

# Skip patterns - files that legitimately mention these patterns
SKIP_PATTERNS = [
    "_pipeline/",
    "pipeline-output/",
    "_extensions/",
    ".git/",
    "data/price_history.parquet",
    "data/nft_floor_history.parquet",
    "scripts/ci/check_secrets.py",  # this file mentions the patterns as examples
    ".env.example",                  # template with empty values
    "CHANGELOG.md",                  # may mention past incidents
    "docs/PACKAGING_PLAN.md",        # example configs
]

# Binary file extensions — random bytes can match hex/base58 regexes.
BINARY_EXTENSIONS = {".parquet", ".db", ".sqlite", ".png", ".jpg", ".jpeg",
                     ".gif", ".pdf", ".zip", ".gz", ".tar", ".woff", ".woff2"}

# False-positive allowlist: placeholder/example strings
ALLOWLIST = {
    "sk-ant-api03-...",
    "sk-...",
    "AIza...",
    "ghp_...",
}


def should_skip(path):
    s = str(path)
    return any(p in s for p in SKIP_PATTERNS)


def is_binary_file(path):
    """Detect binary files via null-byte sniff of first 8KB."""
    if Path(path).suffix.lower() in BINARY_EXTENSIONS:
        return True
    try:
        with open(path, "rb") as fh:
            return b"\x00" in fh.read(8192)
    except (IsADirectoryError, FileNotFoundError, PermissionError):
        return False


def redact(secret):
    """Show only first/last 4 chars so CI logs don't echo the secret."""
    if len(secret) <= 12:
        return "***"
    return "{}...{}".format(secret[:6], secret[-4:])


def scan_file(path):
    """Return list of (line_no, label, redacted) tuples."""
    try:
        content = Path(path).read_text(errors="replace")
    except (IsADirectoryError, FileNotFoundError, PermissionError):
        return []

    violations = []
    for i, line in enumerate(content.splitlines(), start=1):
        for label, rx, _ in PATTERNS:
            for m in rx.finditer(line):
                secret = m.group(0)
                if secret in ALLOWLIST:
                    continue
                # Skip if line explicitly marks as example
                if "example" in line.lower() or "placeholder" in line.lower():
                    continue
                violations.append((i, label, redact(secret)))
    return violations


def get_staged_files():
    result = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"],
        capture_output=True, text=True, check=False,
    )
    return [f for f in result.stdout.splitlines() if f] if result.returncode == 0 else []


def main():
    files = sys.argv[1:] or get_staged_files()
    if not files:
        print("[check_secrets] No files to scan.")
        return 0

    total = 0
    for f in files:
        if should_skip(f) or not Path(f).exists():
            continue
        if is_binary_file(f):
            continue
        violations = scan_file(f)
        if violations:
            total += len(violations)
            print("\n{}:".format(f))
            for line_no, label, redacted in violations:
                print("  line {}: {} secret {} (redacted)".format(line_no, label, redacted))

    if total > 0:
        print("\n" + "=" * 60)
        print("BLOCKED: {} secret(s) found in staged files.".format(total))
        print("")
        print("Rotate the leaked secrets IMMEDIATELY at the provider:")
        print("  Anthropic:   https://console.anthropic.com/settings/keys")
        print("  OpenAI:      https://platform.openai.com/api-keys")
        print("  Google:      https://console.cloud.google.com/apis/credentials")
        print("  ElevenLabs:  https://elevenlabs.io/app/settings/api-keys")
        print("  GitHub:      https://github.com/settings/tokens")
        print("")
        print("Then remove from code and use ~/.config/crypto_swarms/ or env vars.")
        print("If this is a false positive, add to ALLOWLIST or SKIP_PATTERNS.")
        print("=" * 60)
        return 1

    print("[check_secrets] OK ({} file(s) scanned)".format(len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
