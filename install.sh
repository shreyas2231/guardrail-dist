#!/usr/bin/env bash
# Guardrail installer — local AI spend firewall for coding agents.
#
#   curl -fsSL https://raw.githubusercontent.com/Neatproxy/guardrail-dist/main/install.sh | bash
#
# Downloads the right prebuilt binary from the PUBLIC distribution repo and
# installs it to ~/.local/bin (or $GUARDRAIL_INSTALL_DIR). No GitHub account or
# token needed — the source repo stays private; only binaries are published here.
set -euo pipefail

REPO="${GUARDRAIL_REPO:-Neatproxy/guardrail-dist}"
INSTALL_DIR="${GUARDRAIL_INSTALL_DIR:-$HOME/.local/bin}"
CHANNEL="${GUARDRAIL_CHANNEL:-stable}" # stable (default) or beta
VERSION="${GUARDRAIL_VERSION:-latest}" # "latest" or a tag like v0.5.0 / v0.9.2-beta.1

say() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
err() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- args (override env) ---
# Piped form:  curl -fsSL .../install.sh | bash -s -- --channel beta
# Args exist because the intuitive `GUARDRAIL_CHANNEL=beta curl ... | bash`
# scopes the variable to curl, not bash, and silently installs stable.
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --version) VERSION="${2:-}"; shift 2 ;;
    beta|stable) CHANNEL="$1"; shift ;;   # bare word convenience: `bash -s -- beta`
    *) err "unknown argument: $1 (supported: --channel beta|stable, --version vX.Y.Z, or a bare channel name)" ;;
  esac
done

# --- detect platform ---
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"
case "$os" in linux|darwin) ;; *) err "unsupported OS: $os (linux/darwin only)";; esac
case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) err "unsupported arch: $arch" ;;
esac
asset="guardrail_${os}_${arch}.tar.gz"

# --- resolve version by channel ---
# stable = GitHub's "latest" release (never a prerelease).
# beta   = the newest release marked prerelease (how beta builds are published);
#          beta binaries are built against the STAGING backend for real testing.
# An explicit GUARDRAIL_VERSION always wins over the channel.
if [ "$VERSION" = "latest" ] && [ "$CHANNEL" = "beta" ]; then
  # Buffer the response, then parse without early-exit: an awk `exit` mid-stream
  # SIGPIPEs curl, and under `set -euo pipefail` that killed the script silently.
  releases_json="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=20" 2>/dev/null)" \
    || err "could not query releases for $REPO (GitHub API unreachable or rate-limited)"
  VERSION="$(printf '%s' "$releases_json" \
    | awk -F'"' '/"tag_name":/ {tag=$4} /"prerelease": true/ && !found {v=tag; found=1} END {print v}')"
  [ -n "$VERSION" ] || err "no beta release found on $REPO (channel=beta)"
  say "Beta channel resolved to $VERSION"
elif [ "$CHANNEL" != "stable" ] && [ "$CHANNEL" != "beta" ]; then
  err "unknown GUARDRAIL_CHANNEL '$CHANNEL' (stable|beta)"
fi

# --- resolve download URLs (public release assets; no auth) ---
if [ "$VERSION" = "latest" ]; then
  base="https://github.com/$REPO/releases/latest/download"
else
  base="https://github.com/$REPO/releases/download/$VERSION"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
say "Downloading $asset ($VERSION)"
curl -fsSL "$base/$asset" -o "$tmp/$asset" \
  || err "download failed — is the release published? ($base/$asset)"

# --- verify checksum (defense-in-depth beyond HTTPS) ---
if curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" 2>/dev/null; then
  # checksums.txt entries may be "<hash>  name" or "<hash>  ./name".
  expected="$(awk -v a="$asset" '$2==a || $2=="./"a {print $1; exit}' "$tmp/checksums.txt")"
  [ -n "$expected" ] || err "checksums.txt has no entry for $asset"
  if command -v sha256sum >/dev/null 2>&1; then actual="$(sha256sum "$tmp/$asset" | awk '{print $1}')"
  else actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"; fi
  [ "$actual" = "$expected" ] || err "checksum mismatch for $asset (expected $expected, got $actual) — refusing to install"
  say "Checksum verified"
else
  printf '\033[1;33mwarning:\033[0m no checksums.txt for this release; skipping integrity check\n' >&2
fi

# --- extract + install ---
tar -C "$tmp" -xzf "$tmp/$asset"
[ -f "$tmp/guardrail" ] || err "archive did not contain the guardrail binary"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$tmp/guardrail" "$INSTALL_DIR/guardrail"
say "Installed guardrail to $INSTALL_DIR/guardrail"

# macOS Gatekeeper: clear the quarantine flag on the unsigned binary.
if [ "$os" = "darwin" ]; then xattr -d com.apple.quarantine "$INSTALL_DIR/guardrail" 2>/dev/null || true; fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) printf '\n\033[1;33mNote:\033[0m add %s to your PATH:\n  export PATH="%s:$PATH"\n' "$INSTALL_DIR" "$INSTALL_DIR" ;;
esac

cat <<'EOF'

Next steps:
  guardrail start                    # background server + dashboard on http://localhost:4000
  guardrail connect claude-code      # keyless passthrough (uses your existing login)
  guardrail connect codex            # keyless usage telemetry (OTEL)
  guardrail doctor                   # verify
  open http://localhost:4000

Update any time:  guardrail update
EOF
