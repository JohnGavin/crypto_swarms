"""Tests for scripts/ci/check_addresses.py and scripts/ci/check_secrets.py."""
import subprocess
import sys
import tempfile
from pathlib import Path

# Run from project root
PROJECT_ROOT = Path(__file__).parent.parent


def run_check(script, files):
    """Run a CI check script and return (returncode, stdout, stderr)."""
    result = subprocess.run(
        [sys.executable, str(PROJECT_ROOT / script)] + [str(f) for f in files],
        capture_output=True, text=True, cwd=str(PROJECT_ROOT),
    )
    return result.returncode, result.stdout, result.stderr


# ---- check_addresses.py ----

def test_addresses_pass_on_clean_files():
    """Clean files should pass with exit 0."""
    rc, out, _ = run_check("scripts/ci/check_addresses.py", ["tproject.toml"])
    assert rc == 0, out
    assert "OK" in out


def test_addresses_pass_allowlisted_mints():
    """Allowlisted Solana mints (SOL, USDC, USDT) should not trigger."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
        f.write('MINT = "So11111111111111111111111111111111111111112"\n')
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_addresses.py", [f.name])
    Path(f.name).unlink()
    assert rc == 0, out


def test_addresses_block_unknown_solana_address():
    """A non-allowlisted Solana address should be blocked."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
        f.write('WALLET = "So11111111111111111111111111111111111111113"\n')
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_addresses.py", [f.name])
    Path(f.name).unlink()
    assert rc == 1, "Expected block"
    assert "BLOCKED" in out


def test_addresses_block_ethereum_address():
    """A non-allowlisted Ethereum address should be blocked."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
        f.write('ADDR = "0x1234567890abcdef1234567890abcdef12345678"\n')
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_addresses.py", [f.name])
    Path(f.name).unlink()
    assert rc == 1, "Expected block"
    assert "BLOCKED" in out


def test_addresses_truncates_in_output():
    """Blocked address should be truncated in error output (not echoed fully)."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".py", delete=False) as f:
        fake_addr = "So11111111111111111111111111111111111111113"
        f.write('x = "{}"\n'.format(fake_addr))
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_addresses.py", [f.name])
    Path(f.name).unlink()
    assert fake_addr not in out, "Full address leaked in output"
    assert "So11...1113" in out, "Truncated form expected"


# ---- check_secrets.py ----

def test_secrets_pass_on_clean_files():
    """Clean files should pass."""
    rc, out, _ = run_check("scripts/ci/check_secrets.py", ["tproject.toml"])
    assert rc == 0, out
    assert "OK" in out


def test_secrets_block_anthropic_key():
    """An Anthropic API key pattern should be blocked."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        fake = "sk-ant-api03-" + "A" * 90
        f.write("KEY={}\n".format(fake))
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_secrets.py", [f.name])
    Path(f.name).unlink()
    assert rc == 1, "Expected block"
    assert "BLOCKED" in out


def test_secrets_block_openai_key():
    """An OpenAI API key pattern should be blocked."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        fake = "sk-proj-" + "B" * 50
        f.write(fake + "\n")
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_secrets.py", [f.name])
    Path(f.name).unlink()
    assert rc == 1, "Expected block"
    assert "BLOCKED" in out


def test_secrets_block_github_token():
    """A GitHub PAT should be blocked."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        fake = "ghp_" + "C" * 40
        f.write(fake + "\n")
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_secrets.py", [f.name])
    Path(f.name).unlink()
    assert rc == 1, "Expected block"
    assert "BLOCKED" in out


def test_secrets_redacts_in_output():
    """Secrets should be redacted (first6...last4) in error output."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
        fake = "sk-ant-api03-" + "X" * 90
        f.write(fake + "\n")
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_secrets.py", [f.name])
    Path(f.name).unlink()
    assert fake not in out, "Full secret leaked"
    assert "sk-ant" in out, "Redacted prefix expected"
    assert "(redacted)" in out


def test_secrets_skip_env_example():
    """.env.example should be skipped (it mentions key names but has no values)."""
    rc, out, _ = run_check("scripts/ci/check_secrets.py", [".env.example"])
    assert rc == 0, out


# ---- binary-file skip (regression: parquet false positive, run #92) ----

def test_addresses_skip_binary_by_null_bytes():
    """A binary file containing base58-shaped bytes must not trigger the scanner."""
    fake_addr = b"So11111111111111111111111111111111111111113"
    payload = b"PAR1\x00\x00" + fake_addr + b"\x00\x00\x00 some\x00bytes"
    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(payload)
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_addresses.py", [f.name])
    Path(f.name).unlink()
    assert rc == 0, out

def test_addresses_skip_binary_by_extension():
    """A .parquet file must be skipped even if its bytes look like base58."""
    fake_addr = b"So11111111111111111111111111111111111111113"
    with tempfile.NamedTemporaryFile(suffix=".parquet", delete=False) as f:
        f.write(b"PAR1" + fake_addr + b"PAR1")  # no null bytes; extension catches it
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_addresses.py", [f.name])
    Path(f.name).unlink()
    assert rc == 0, out

def test_secrets_skip_binary_files():
    """check_secrets must also skip binary files (elevenlabs 32-hex regex hits parquet bytes)."""
    payload = b"PAR1\x00" + (b"abcdef0123456789" * 4) + b"\x00 binary"
    with tempfile.NamedTemporaryFile(suffix=".parquet", delete=False) as f:
        f.write(payload)
        f.flush()
        rc, out, _ = run_check("scripts/ci/check_secrets.py", [f.name])
    Path(f.name).unlink()
    assert rc == 0, out


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
