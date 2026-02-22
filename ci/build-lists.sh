#!/bin/bash
# build-lists.sh — Build domain + CIDR lists for GitHub Releases
# Runs in CI (GitHub Actions). NOT for routers (uses bash, jq, whois, python3).
#
# Pipeline:
#   1. Download domain lists from upstream sources
#   2. Fetch CIDRs from official provider APIs (Google, Meta, Telegram, etc.)
#   3. Resolve all domains → IPs via multiple DNS servers (resolve-domains.py)
#   4. Aggregate resolved IPs into CIDRs (/24 for clusters, /32 for singles)
#   5. Merge: domains + provider CIDRs + resolved CIDRs → per-service .lst files
#   6. Publish as GitHub Release

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCES_CONF="$SCRIPT_DIR/sources.conf"
CIDRS_DIR="$SCRIPT_DIR/cidrs"
OUTPUT_DIR="$ROOT_DIR/output"
TMP_DIR=$(mktemp -d)

trap 'rm -rf "$TMP_DIR"' EXIT

log() { echo "[build] $1"; }
err() { echo "[build] ERROR: $1" >&2; }

# ── Validate prerequisites ───────────────────────────────────────
for cmd in curl jq whois sha256sum python3; do
    command -v "$cmd" >/dev/null 2>&1 || { err "$cmd not found"; exit 1; }
done

# Check dnspython is available; auto-create venv if needed (for local dev on macOS/etc.)
if ! python3 -c "import dns.asyncresolver" 2>/dev/null; then
    log "dnspython not found, setting up venv..."
    VENV_DIR="$SCRIPT_DIR/.venv"
    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        "$VENV_DIR/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
    fi
    # Re-check with venv python
    if "$VENV_DIR/bin/python3" -c "import dns.asyncresolver" 2>/dev/null; then
        # Use venv python for the rest of the script
        export PATH="$VENV_DIR/bin:$PATH"
        log "Using venv at $VENV_DIR"
    else
        err "dnspython not found even after venv setup. Install: pip install dnspython"
        exit 1
    fi
fi

RESOLVER_SCRIPT="$SCRIPT_DIR/resolve-domains.py"
[ -f "$RESOLVER_SCRIPT" ] || { err "resolve-domains.py not found at $RESOLVER_SCRIPT"; exit 1; }

[ -f "$SOURCES_CONF" ] || { err "sources.conf not found at $SOURCES_CONF"; exit 1; }

mkdir -p "$OUTPUT_DIR" "$TMP_DIR/domains" "$TMP_DIR/cidrs"

# ── Fetch CIDRs from official provider APIs ──────────────────────

fetch_cidrs() {
    local provider="$1"
    local outfile="$TMP_DIR/cidrs/${provider}.txt"

    case "$provider" in
        google)
            log "Fetching Google CIDRs (goog.json)..."
            curl -sL -f -m 30 "https://www.gstatic.com/ipranges/goog.json" \
                | jq -r '.prefixes[].ipv4Prefix // empty' \
                | grep -E '^[0-9]' \
                | sort -u > "$outfile" 2>/dev/null || true
            ;;
        meta)
            log "Fetching Meta CIDRs (AS32934)..."
            whois -h whois.radb.net -- '-i origin AS32934' 2>/dev/null \
                | grep '^route:' \
                | awk '{print $2}' \
                | grep -E '^[0-9]' \
                | sort -u > "$outfile" || true
            ;;
        telegram)
            log "Fetching Telegram CIDRs..."
            curl -sL -f -m 30 "https://core.telegram.org/resources/cidr.txt" \
                | grep -E '^[0-9]' \
                | sort -u > "$outfile" 2>/dev/null || true
            ;;
        twitter)
            log "Fetching Twitter/X CIDRs (AS13414)..."
            whois -h whois.radb.net -- '-i origin AS13414' 2>/dev/null \
                | grep '^route:' \
                | awk '{print $2}' \
                | grep -E '^[0-9]' \
                | sort -u > "$outfile" || true
            ;;
        apple)
            log "Fetching Apple CIDRs (AS714)..."
            whois -h whois.radb.net -- '-i origin AS714' 2>/dev/null \
                | grep '^route:' \
                | awk '{print $2}' \
                | grep -E '^[0-9]' \
                | sort -u > "$outfile" || true
            ;;
        none)
            # No CIDR provider for this service
            touch "$outfile"
            ;;
        *)
            err "Unknown CIDR provider: $provider"
            touch "$outfile"
            ;;
    esac

    if [ -s "$outfile" ]; then
        log "  $provider: $(wc -l < "$outfile") CIDRs"
    elif [ "$provider" != "none" ]; then
        err "  $provider: no CIDRs fetched (will continue without)"
    fi
}

# Collect unique providers
providers=""
while IFS='|' read -r slug display_name upstream_url cidr_provider; do
    [ -z "$slug" ] && continue
    [[ "$slug" =~ ^# ]] && continue
    if [ "$cidr_provider" != "none" ] && ! echo "$providers" | grep -qw "$cidr_provider"; then
        providers="$providers $cidr_provider"
    fi
done < "$SOURCES_CONF"

# Fetch CIDRs in parallel
log "=== Fetching CIDRs ==="
pids=""
for provider in $providers; do
    fetch_cidrs "$provider" &
    pids="$pids $!"
done

# Wait for all CIDR fetches
for pid in $pids; do
    wait "$pid" || true
done

# ── Download domain lists from upstream ──────────────────────────

log ""
log "=== Downloading domain lists ==="

download_domains() {
    local slug="$1"
    local url="$2"
    local outfile="$TMP_DIR/domains/${slug}.txt"

    if curl -sL -f -m 30 "$url" > "$outfile" 2>/dev/null; then
        local count
        count=$(wc -l < "$outfile")
        log "  $slug: $count entries"
    else
        err "  $slug: download failed ($url)"
        rm -f "$outfile"
    fi
}

pids=""
while IFS='|' read -r slug display_name upstream_url cidr_provider; do
    [ -z "$slug" ] && continue
    [[ "$slug" =~ ^# ]] && continue
    download_domains "$slug" "$upstream_url" &
    pids="$pids $!"
done < "$SOURCES_CONF"

for pid in $pids; do
    wait "$pid" || true
done

# ── Resolve domains → IPs → CIDRs ───────────────────────────────

log ""
log "=== Resolving domains to IPs ==="

mkdir -p "$TMP_DIR/resolved"

# Resolve each service's domains to CIDRs via DNS (parallel)
resolve_service() {
    local slug="$1"
    local domain_file="$TMP_DIR/domains/${slug}.txt"
    local resolved_file="$TMP_DIR/resolved/${slug}.cidrs"

    if [ -f "$domain_file" ] && [ -s "$domain_file" ]; then
        python3 "$RESOLVER_SCRIPT" --file "$domain_file" --out "$resolved_file" 2>&1 || {
            echo "[build] ERROR: $slug: DNS resolution failed (continuing without)" >&2
            touch "$resolved_file"
        }
    else
        touch "$resolved_file"
    fi
}

pids=""
while IFS='|' read -r slug display_name upstream_url cidr_provider; do
    [ -z "$slug" ] && continue
    [[ "$slug" =~ ^# ]] && continue
    resolve_service "$slug" &
    pids="$pids $!"
done < "$SOURCES_CONF"

for pid in $pids; do
    wait "$pid" || true
done

# ── Build per-service files ──────────────────────────────────────

log ""
log "=== Building per-service files ==="

clean_entries() {
    # Remove BOM, carriage returns, leading/trailing whitespace, comments, blank lines
    # Then deduplicate
    sed 's/\xef\xbb\xbf//g' \
        | tr -d '\r' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | grep -v '^#\|^$\|^[[:space:]]*$' \
        | sort -u
}

total_services=0
total_domains=0
total_cidrs=0

while IFS='|' read -r slug display_name upstream_url cidr_provider; do
    [ -z "$slug" ] && continue
    [[ "$slug" =~ ^# ]] && continue

    outfile="$OUTPUT_DIR/${slug}.lst"
    tmpmerge="$TMP_DIR/merge_${slug}.txt"
    > "$tmpmerge"

    # Add downloaded domains (echo ensures trailing newline if source lacks one)
    if [ -f "$TMP_DIR/domains/${slug}.txt" ]; then
        { cat "$TMP_DIR/domains/${slug}.txt"; echo; } >> "$tmpmerge"
    fi

    # Add CIDRs from provider API (Google goog.json, Meta RADB, etc.)
    if [ "$cidr_provider" != "none" ] && [ -f "$TMP_DIR/cidrs/${cidr_provider}.txt" ]; then
        { cat "$TMP_DIR/cidrs/${cidr_provider}.txt"; echo; } >> "$tmpmerge"
    fi

    # Add CIDRs from DNS resolution (domains resolved → IPs → aggregated CIDRs)
    if [ -f "$TMP_DIR/resolved/${slug}.cidrs" ] && [ -s "$TMP_DIR/resolved/${slug}.cidrs" ]; then
        { cat "$TMP_DIR/resolved/${slug}.cidrs"; echo; } >> "$tmpmerge"
    fi

    # Add manual CIDR overrides if exist
    if [ -f "$CIDRS_DIR/${slug}.txt" ]; then
        { cat "$CIDRS_DIR/${slug}.txt"; echo; } >> "$tmpmerge"
    fi

    # Clean and deduplicate
    clean_entries < "$tmpmerge" > "$outfile"

    # Count domains vs CIDRs
    _cidrs=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' "$outfile" 2>/dev/null) || _cidrs=0
    _total=$(wc -l < "$outfile")
    _domains=$((_total - _cidrs))

    log "  $slug.lst: $_total entries ($_domains domains, $_cidrs CIDRs)"

    total_services=$((total_services + 1))
    total_domains=$((total_domains + _domains))
    total_cidrs=$((total_cidrs + _cidrs))

done < "$SOURCES_CONF"

# ── Generate manifest ────────────────────────────────────────────

log ""
log "=== Generating manifest ==="

BUILD_DATE=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
VERSION=$(date -u '+%Y%m%d%H%M%S')

{
    echo "version=$VERSION"
    echo "date=$BUILD_DATE"
    echo "services=$total_services"
    echo "total_domains=$total_domains"
    echo "total_cidrs=$total_cidrs"
    echo ""
    echo "# sha256 checksums"
    for f in "$OUTPUT_DIR"/*.lst; do
        [ -f "$f" ] || continue
        _sum=$(sha256sum "$f" | awk '{print $1}')
        _name=$(basename "$f")
        echo "$_sum  $_name"
    done
} > "$OUTPUT_DIR/manifest.txt"

log "Manifest: version=$VERSION, $total_services services, $total_domains domains, $total_cidrs CIDRs"

# ── Summary ──────────────────────────────────────────────────────

log ""
log "=== Build complete ==="
log "Output directory: $OUTPUT_DIR"
log "Files: $(ls "$OUTPUT_DIR"/*.lst 2>/dev/null | wc -l) service lists + manifest.txt"
log "Total: $total_domains domains + $total_cidrs CIDRs across $total_services services"
