#!/usr/bin/env python3
"""
resolve-domains.py — Resolve domain lists to IPs and aggregate into CIDRs.

Reads domain files, resolves each domain against multiple DNS servers
in parallel (async), filters stubs, aggregates into /24 CIDRs where
IPs cluster, and outputs CIDR-notation results.

Similar to DomainMapper's approach but optimized for CI batch processing.

Usage:
    python3 resolve-domains.py input_dir/ output_dir/
    python3 resolve-domains.py --file youtube.txt --out youtube-cidrs.txt
"""

import argparse
import asyncio
import ipaddress
import os
import sys
import time
from collections import defaultdict
from pathlib import Path

try:
    import dns.asyncresolver
    import dns.resolver
except ImportError:
    print("ERROR: dnspython is required. Install with: pip install dnspython", file=sys.stderr)
    sys.exit(1)


# ── Configuration ─────────────────────────────────────────────────

DNS_SERVERS = [
    ("Google", ["8.8.8.8", "8.8.4.4"]),
    ("Cloudflare", ["1.1.1.1", "1.0.0.1"]),
    ("Quad9", ["9.9.9.9", "149.112.112.112"]),
]

RATE_LIMIT = 50          # queries per second per DNS server
RESOLVER_TIMEOUT = 10.0  # per-query timeout
RESOLVER_LIFETIME = 15.0 # total lifetime for retries
BATCH_SIZE = 500         # domains per batch to limit memory
STUB_IPS = frozenset({"127.0.0.1", "0.0.0.0"})


# ── Rate limiter ──────────────────────────────────────────────────

class RateLimiter:
    """Sliding window rate limiter (per DNS server)."""

    def __init__(self, rate: int):
        self.rate = rate
        self.timestamps = []
        self.lock = asyncio.Lock()

    async def acquire(self):
        async with self.lock:
            now = time.monotonic()
            # Remove timestamps older than 1 second
            self.timestamps = [t for t in self.timestamps if now - t < 1.0]
            if len(self.timestamps) >= self.rate:
                sleep_time = 1.0 - (now - self.timestamps[0])
                if sleep_time > 0:
                    await asyncio.sleep(sleep_time)
                now = time.monotonic()
                self.timestamps = [t for t in self.timestamps if now - t < 1.0]
            self.timestamps.append(now)


# ── DNS Resolution ────────────────────────────────────────────────

async def resolve_domain(domain: str, resolver: dns.asyncresolver.Resolver,
                         limiter: RateLimiter) -> set:
    """Resolve a single domain to a set of IPv4 addresses."""
    await limiter.acquire()
    try:
        response = await resolver.resolve(domain, "A")
        return {rdata.address for rdata in response}
    except (dns.resolver.NoNameservers, dns.resolver.Timeout,
            dns.resolver.NXDOMAIN, dns.resolver.NoAnswer,
            dns.resolver.LifetimeTimeout, Exception):
        return set()


async def resolve_batch(domains: list, server_name: str, nameservers: list,
                        limiter: RateLimiter, stats: dict) -> set:
    """Resolve a batch of domains against one DNS server."""
    resolver = dns.asyncresolver.Resolver()
    resolver.nameservers = nameservers
    resolver.timeout = RESOLVER_TIMEOUT
    resolver.lifetime = RESOLVER_LIFETIME

    all_ips = set()
    tasks = [resolve_domain(d, resolver, limiter) for d in domains]
    results = await asyncio.gather(*tasks, return_exceptions=True)

    for result in results:
        if isinstance(result, set):
            for ip in result:
                if ip not in STUB_IPS and ip not in nameservers:
                    all_ips.add(ip)
                else:
                    stats["filtered"] += 1
            stats["resolved"] += 1
        else:
            stats["errors"] += 1

    return all_ips


async def resolve_domains(domains: list, stats: dict) -> set:
    """Resolve all domains against all DNS servers, return unique IPs."""
    all_ips = set()

    # Process in batches to limit concurrency
    for batch_start in range(0, len(domains), BATCH_SIZE):
        batch = domains[batch_start:batch_start + BATCH_SIZE]

        # Resolve against all DNS servers in parallel
        limiters = {name: RateLimiter(RATE_LIMIT) for name, _ in DNS_SERVERS}
        tasks = []
        for server_name, nameservers in DNS_SERVERS:
            tasks.append(resolve_batch(batch, server_name, nameservers,
                                       limiters[server_name], stats))

        results = await asyncio.gather(*tasks, return_exceptions=True)
        for result in results:
            if isinstance(result, set):
                all_ips.update(result)

        processed = min(batch_start + BATCH_SIZE, len(domains))
        print(f"  resolved {processed}/{len(domains)} domains, "
              f"{len(all_ips)} unique IPs so far", flush=True)

    return all_ips


# ── IP Aggregation ────────────────────────────────────────────────

def aggregate_ips_to_cidrs(ips: set) -> list:
    """
    Aggregate IPs into CIDRs using 'mix' mode:
    - If 2+ IPs share the same /24 prefix -> aggregate to /24
    - Single IPs -> keep as /32
    """
    groups = defaultdict(list)
    for ip_str in ips:
        try:
            ip = ipaddress.IPv4Address(ip_str)
            # Group by first 3 octets (/24 prefix)
            network = ipaddress.IPv4Network(f"{ip_str}/24", strict=False)
            groups[str(network)].append(ip)
        except (ValueError, ipaddress.AddressValueError):
            continue

    cidrs = set()
    for network_str, ip_list in groups.items():
        if len(ip_list) >= 2:
            # 2+ IPs in same /24 -> use the /24
            cidrs.add(network_str)
        else:
            # Single IP -> /32
            cidrs.add(f"{ip_list[0]}/32")

    # Sort by IP address
    return sorted(cidrs, key=lambda x: ipaddress.ip_network(x).network_address)


# ── File Processing ───────────────────────────────────────────────

def read_domains(filepath: str) -> list:
    """Read domains from a file (one per line, skip comments/IPs)."""
    domains = []
    with open(filepath, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip().strip("\ufeff")  # strip BOM
            if not line or line.startswith("#"):
                continue
            # Skip IP/CIDR entries — we only want to resolve domains
            if line[0].isdigit() and ("/" in line or line.replace(".", "").isdigit()):
                continue
            # Basic domain validation
            if "." in line and all(c.isalnum() or c in ".-_" for c in line):
                domains.append(line.lower())
    return list(set(domains))  # deduplicate


async def process_file(input_path: str, output_path: str):
    """Process a single domain file -> CIDR output file."""
    filename = os.path.basename(input_path)
    print(f"\n[resolve] Processing {filename}...", flush=True)

    domains = read_domains(input_path)
    if not domains:
        print(f"  no domains to resolve in {filename}")
        # Write empty file
        Path(output_path).write_text("")
        return

    print(f"  {len(domains)} unique domains to resolve "
          f"against {len(DNS_SERVERS)} DNS servers", flush=True)

    stats = {"resolved": 0, "errors": 0, "filtered": 0}
    start = time.time()

    ips = await resolve_domains(domains, stats)
    elapsed = time.time() - start

    print(f"  DNS resolution: {len(ips)} unique IPs in {elapsed:.1f}s "
          f"(errors: {stats['errors']}, filtered stubs: {stats['filtered']})",
          flush=True)

    if not ips:
        Path(output_path).write_text("")
        return

    cidrs = aggregate_ips_to_cidrs(ips)

    with open(output_path, "w") as f:
        for cidr in cidrs:
            f.write(cidr + "\n")

    print(f"  aggregated to {len(cidrs)} CIDRs ({output_path})", flush=True)


async def process_directory(input_dir: str, output_dir: str):
    """Process all .lst/.txt files in a directory."""
    os.makedirs(output_dir, exist_ok=True)

    files = sorted(
        f for f in os.listdir(input_dir)
        if f.endswith((".lst", ".txt")) and not f.startswith(".")
    )

    if not files:
        print(f"No domain files found in {input_dir}")
        return

    print(f"[resolve] Processing {len(files)} files from {input_dir}")

    for filename in files:
        input_path = os.path.join(input_dir, filename)
        # Output with same name but in output directory
        out_name = os.path.splitext(filename)[0] + ".cidrs"
        output_path = os.path.join(output_dir, out_name)
        await process_file(input_path, output_path)


# ── Main ──────────────────────────────────────────────────────────

def main():
    global RATE_LIMIT

    parser = argparse.ArgumentParser(
        description="Resolve domain lists to IP/CIDR aggregations"
    )
    parser.add_argument(
        "--file", "-f",
        help="Single input file with domains"
    )
    parser.add_argument(
        "--out", "-o",
        help="Output file (with --file) or output directory"
    )
    parser.add_argument(
        "--dir", "-d",
        help="Input directory with domain files"
    )
    parser.add_argument(
        "--rate-limit", "-r",
        type=int, default=RATE_LIMIT,
        help=f"DNS queries per second per server (default: {RATE_LIMIT})"
    )
    args = parser.parse_args()

    RATE_LIMIT = args.rate_limit

    if args.file:
        if not args.out:
            base = os.path.splitext(args.file)[0]
            args.out = base + ".cidrs"
        asyncio.run(process_file(args.file, args.out))
    elif args.dir:
        if not args.out:
            args.out = args.dir + "_cidrs"
        asyncio.run(process_directory(args.dir, args.out))
    else:
        # Default: process positional args as input_dir output_dir
        if len(sys.argv) >= 3:
            asyncio.run(process_directory(sys.argv[1], sys.argv[2]))
        else:
            parser.print_help()
            sys.exit(1)


if __name__ == "__main__":
    main()
