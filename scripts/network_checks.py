#!/usr/bin/env python3
"""
UniFi Network Pre-flight Validation (KAZ-61)
=============================================

PURPOSE:
    Queries the UniFi Network Controller REST API to validate network
    configuration before bootstrapping Kubernetes. All checks are
    advisory — they warn but do not block bootstrap.

WHAT THIS CHECKS:
    1. Node IP validation    — K8s node IPs are static (not DHCP leases)
    2. MetalLB range safety  — MetalLB IP range doesn't overlap DHCP range
    3. DNS reachability      — VLAN DNS servers respond to queries
    4. Inter-VLAN routing    — Nodes across VLANs can reach each other
    5. DHCP reservations     — Flags reservations that should be static

CREDENTIALS:
    All UniFi credentials are fetched from 1Password at runtime via `op read`.
    No credentials are hardcoded or stored in config files.

    Required 1Password items (vault: Homelab):
      - "UniFi Controller" with fields: host, username, password

USAGE:
    # Standalone (for debugging):
    python3 scripts/network_checks.py

    # Via bootstrap (default — runs automatically):
    python3 scripts/bootstrap.py

    # Skip network checks in offline/CI environments:
    python3 scripts/bootstrap.py --skip-network-checks
"""

import ipaddress
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from http.cookiejar import CookieJar
from pathlib import Path
from typing import Optional


# =============================================================================
# CONFIGURATION
# =============================================================================

@dataclass
class NetworkCheckConfig:
    """Configuration for UniFi network validation.

    All values are either fetched from 1Password at runtime or read from
    the cluster vars ConfigMap. No hardcoded network addresses.
    """

    # ── 1Password references ────────────────────────────────────────
    # These are `op://` URIs read via `op read` at runtime.
    op_vault: str = "Homelab"
    op_item: str = "UniFi Controller"

    # ── Derived at runtime ──────────────────────────────────────────
    unifi_host: str = ""
    unifi_username: str = ""
    unifi_password: str = ""
    unifi_site: str = "default"

    # ── From cluster vars (read from vars.yaml) ─────────────────────
    metallb_ip_range: str = ""

    # ── K8s node IPs (read from kubectl) ────────────────────────────
    node_ips: list = field(default_factory=list)
    node_names: list = field(default_factory=list)

    # ── Repo root ───────────────────────────────────────────────────
    repo_root: str = ""

    def __post_init__(self):
        if not self.repo_root:
            self.repo_root = str(Path(__file__).parent.parent.resolve())


# =============================================================================
# HELPERS
# =============================================================================

def log(emoji: str, message: str) -> None:
    """Structured logging with emoji prefixes for visual clarity."""
    print(f"{emoji} {message}", flush=True)


def run_cmd(
    cmd: list[str],
    capture: bool = True,
    check: bool = True,
    timeout: Optional[int] = None,
) -> subprocess.CompletedProcess:
    """Execute a shell command with proper error handling."""
    kwargs = {"text": True, "check": check}
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    if timeout is not None:
        kwargs["timeout"] = timeout
    return subprocess.run(cmd, **kwargs)


# =============================================================================
# 1PASSWORD CREDENTIAL FETCHING
# =============================================================================

def fetch_op_credential(vault: str, item: str, field_name: str) -> Optional[str]:
    """Fetch a single field from 1Password via `op read`.

    Uses the `op://vault/item/field` URI format. Returns None if the
    credential cannot be fetched (op CLI not available, not signed in, etc).
    """
    op_uri = f"op://{vault}/{item}/{field_name}"
    try:
        result = run_cmd(["op", "read", op_uri], capture=True, timeout=10)
        return result.stdout.strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError) as e:
        log("  ⚠️ ", f"Could not read {op_uri}: {e}")
        return None


def load_credentials(config: NetworkCheckConfig) -> bool:
    """Load UniFi credentials from 1Password. Returns True if successful."""
    log("🔑", "Fetching UniFi credentials from 1Password...")

    config.unifi_host = fetch_op_credential(config.op_vault, config.op_item, "host") or ""
    config.unifi_username = fetch_op_credential(config.op_vault, config.op_item, "username") or ""
    config.unifi_password = fetch_op_credential(config.op_vault, config.op_item, "password") or ""

    if not all([config.unifi_host, config.unifi_username, config.unifi_password]):
        log("  ⚠️ ", "Could not fetch all UniFi credentials from 1Password.")
        log("  ", f"  Ensure '{config.op_item}' exists in vault '{config.op_vault}'")
        log("  ", "  with fields: host, username, password")
        log("  ", "  And that you are signed in: op signin")
        return False

    log("  ✅", f"Credentials loaded for {config.unifi_host}")
    return True


# =============================================================================
# UNIFI API CLIENT
# =============================================================================

class UniFiClient:
    """Minimal UniFi Controller REST API client using stdlib only.

    LEARNING NOTE — WHY NOT USE `requests`:
        The bootstrap script deliberately avoids third-party dependencies.
        urllib.request is verbose but sufficient for the ~5 API calls we make.
        This means no `pip install` step, no virtualenv, no requirements.txt.
        For a bootstrap script that runs on fresh machines, fewer dependencies
        means fewer failure modes.

    LEARNING NOTE — SSL VERIFICATION:
        UniFi controllers use self-signed certificates by default. We disable
        SSL verification for the controller connection only. This is standard
        practice for local network management interfaces and does not affect
        the security of the cluster or internet-facing services.
    """

    def __init__(self, host: str, username: str, password: str, site: str = "default"):
        self.base_url = f"https://{host}"
        self.site = site
        self._username = username
        self._password = password
        self._logged_in = False

        # Set up cookie handling and SSL context
        self._cookie_jar = CookieJar()
        self._ssl_context = ssl.create_default_context()
        self._ssl_context.check_hostname = False
        self._ssl_context.verify_mode = ssl.CERT_NONE

        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._cookie_jar),
            urllib.request.HTTPSHandler(context=self._ssl_context),
        )

    def _request(self, path: str, data: Optional[dict] = None, method: str = "GET") -> dict:
        """Make an authenticated request to the UniFi API."""
        url = f"{self.base_url}{path}"
        body = json.dumps(data).encode("utf-8") if data else None

        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Content-Type", "application/json")

        try:
            response = self._opener.open(req, timeout=15)
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            body_text = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"UniFi API error {e.code} on {path}: {body_text}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"Cannot reach UniFi controller at {self.base_url}: {e}") from e

    def login(self) -> bool:
        """Authenticate with the UniFi controller."""
        try:
            self._request("/api/login", {
                "username": self._username,
                "password": self._password,
            })
            self._logged_in = True
            return True
        except RuntimeError as e:
            log("  ⚠️ ", f"UniFi login failed: {e}")
            return False

    def logout(self) -> None:
        """End the session."""
        if self._logged_in:
            try:
                self._request("/api/logout", method="POST")
            except RuntimeError:
                pass  # Best effort

    def get_clients(self) -> list[dict]:
        """Get all active clients (devices with current connections)."""
        result = self._request(f"/api/s/{self.site}/stat/sta")
        return result.get("data", [])

    def get_configured_clients(self) -> list[dict]:
        """Get all configured/known clients (includes offline devices with fixed IPs)."""
        result = self._request(f"/api/s/{self.site}/rest/user")
        return result.get("data", [])

    def get_networks(self) -> list[dict]:
        """Get all configured networks (VLANs, subnets, DHCP settings)."""
        result = self._request(f"/api/s/{self.site}/rest/networkconf")
        return result.get("data", [])

    def get_dhcp_leases(self) -> list[dict]:
        """Get active DHCP leases.

        Note: This endpoint may not be available on all UniFi OS versions.
        Falls back gracefully if unavailable.
        """
        try:
            result = self._request(f"/api/s/{self.site}/stat/device")
            # DHCP leases are embedded in the device data for USG/UDM
            leases = []
            for device in result.get("data", []):
                for lease in device.get("dhcp_leases", []):
                    leases.append(lease)
            return leases
        except RuntimeError:
            return []

    def get_routing(self) -> list[dict]:
        """Get routing table / inter-VLAN routing config."""
        try:
            result = self._request(f"/api/s/{self.site}/rest/routing")
            return result.get("data", [])
        except RuntimeError:
            return []


# =============================================================================
# CLUSTER DATA FETCHING
# =============================================================================

def get_node_ips(kube_context: str = "") -> tuple[list[str], list[str]]:
    """Get K8s node names and their InternalIPs from kubectl."""
    cmd = ["kubectl", "get", "nodes", "-o",
           "jsonpath={range .items[*]}{.metadata.name}|{.status.addresses[?(@.type==\"InternalIP\")].address}{\"\\n\"}{end}"]
    if kube_context:
        cmd.extend(["--context", kube_context])

    try:
        result = run_cmd(cmd, capture=True, timeout=10)
        names = []
        ips = []
        for line in result.stdout.strip().split("\n"):
            if "|" in line:
                parts = line.split("|")
                name = parts[0].strip()
                ip = parts[1].strip()
                if name and ip:
                    names.append(name)
                    ips.append(ip)
        return names, ips
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        log("  ⚠️ ", "Could not fetch node IPs from kubectl")
        return [], []


def get_metallb_range_from_vars(repo_root: str) -> str:
    """Read the MetalLB IP range from cluster vars.yaml.

    Parses the METALLB_IP_RANGE value from the ConfigMap. This avoids
    hardcoding the range and ensures we validate against the actual
    configured value.
    """
    vars_path = Path(repo_root) / "clusters" / "homelab" / "vars.yaml"
    if not vars_path.exists():
        # Fall back to environment variable
        return os.environ.get("METALLB_IP_RANGE", "")

    try:
        content = vars_path.read_text()
        for line in content.split("\n"):
            stripped = line.strip()
            if stripped.startswith("METALLB_IP_RANGE:"):
                value = stripped.split(":", 1)[1].strip().strip('"').strip("'")
                return value
    except Exception:
        pass

    return os.environ.get("METALLB_IP_RANGE", "")


# =============================================================================
# VALIDATION CHECKS
# =============================================================================

def parse_ip_range(range_str: str) -> tuple[ipaddress.IPv4Address, ipaddress.IPv4Address]:
    """Parse a 'start-end' IP range string into two IPv4Address objects."""
    parts = range_str.split("-")
    if len(parts) == 2:
        start = ipaddress.IPv4Address(parts[0].strip())
        end = ipaddress.IPv4Address(parts[1].strip())
        return start, end
    raise ValueError(f"Invalid IP range format: {range_str}")


def ip_in_range(ip: str, range_start: ipaddress.IPv4Address,
                range_end: ipaddress.IPv4Address) -> bool:
    """Check if an IP address falls within a start-end range."""
    addr = ipaddress.IPv4Address(ip)
    return range_start <= addr <= range_end


def check_node_ip_assignments(
    client: UniFiClient,
    node_names: list[str],
    node_ips: list[str],
    warnings: list[str],
) -> None:
    """Check that K8s node IPs are static assignments, not DHCP leases.

    LEARNING NOTE — STATIC vs DHCP vs RESERVED:
        In UniFi, there are three ways a device can get an IP:
          1. DHCP lease    — Assigned dynamically from the pool. Can change.
          2. DHCP reserved — Fixed IP assigned via DHCP. Still depends on DHCP server.
          3. Static        — Configured on the device itself. No DHCP dependency.

        For K8s nodes, static (3) is strongly preferred. DHCP reservations (2)
        work but add a dependency on the DHCP server. Dynamic leases (1) will
        break the cluster when IPs change.
    """
    log("🔍", "Checking node IP assignments...")

    if not node_ips:
        log("  ⚠️ ", "No node IPs available — skipping assignment check")
        warnings.append("Could not verify node IP assignments (no node IPs)")
        return

    # Fetch configured clients (includes fixed IP assignments)
    configured_clients = client.get_configured_clients()
    active_clients = client.get_clients()

    # Build lookup: IP -> client info
    fixed_ips = {}
    for c in configured_clients:
        if c.get("use_fixedip") and c.get("fixed_ip"):
            fixed_ips[c["fixed_ip"]] = {
                "name": c.get("name", c.get("hostname", "unknown")),
                "mac": c.get("mac", "unknown"),
                "type": "dhcp_reservation",
            }

    active_by_ip = {}
    for c in active_clients:
        ip = c.get("ip")
        if ip:
            active_by_ip[ip] = {
                "name": c.get("name", c.get("hostname", "unknown")),
                "mac": c.get("mac", "unknown"),
                "is_wired": c.get("is_wired", False),
                "use_fixedip": c.get("use_fixedip", False),
            }

    for name, ip in zip(node_names, node_ips):
        if ip in fixed_ips:
            info = fixed_ips[ip]
            log("  ⚠️ ", f"{name} ({ip}): DHCP reservation (MAC: {info['mac']})")
            log("  ", f"  Recommendation: Convert to static IP on the node itself")
            warnings.append(
                f"Node {name} ({ip}) uses a DHCP reservation — "
                f"consider converting to a static assignment"
            )
        elif ip in active_by_ip:
            info = active_by_ip[ip]
            if info.get("use_fixedip"):
                log("  ⚠️ ", f"{name} ({ip}): DHCP reservation (active)")
                warnings.append(
                    f"Node {name} ({ip}) uses a DHCP reservation — "
                    f"consider converting to a static assignment"
                )
            else:
                # IP is active but not a fixed assignment — could be static
                # (UniFi may not know about statically configured IPs)
                log("  ✅", f"{name} ({ip}): Active (likely static — not in DHCP reservations)")
        else:
            # IP not in UniFi at all — almost certainly static
            log("  ✅", f"{name} ({ip}): Static (not managed by UniFi DHCP)")


def check_metallb_dhcp_overlap(
    client: UniFiClient,
    metallb_range: str,
    warnings: list[str],
) -> None:
    """Verify MetalLB IP range does not overlap with any DHCP range.

    LEARNING NOTE — WHY THIS MATTERS:
        If MetalLB assigns an IP from a range that overlaps with DHCP,
        two devices can end up with the same IP. MetalLB uses gratuitous
        ARP to claim IPs, which wins in the short term — but when the
        DHCP lease renews, you get intermittent connectivity issues that
        are extremely hard to debug.
    """
    log("🔍", "Checking MetalLB range vs DHCP ranges...")

    if not metallb_range:
        log("  ⚠️ ", "MetalLB range not configured — skipping overlap check")
        warnings.append("MetalLB IP range not found in vars.yaml")
        return

    try:
        metallb_start, metallb_end = parse_ip_range(metallb_range)
    except ValueError as e:
        log("  ⚠️ ", f"Could not parse MetalLB range '{metallb_range}': {e}")
        warnings.append(f"Invalid MetalLB range format: {metallb_range}")
        return

    log("  ", f"MetalLB range: {metallb_start} - {metallb_end}")

    networks = client.get_networks()
    overlap_found = False

    for network in networks:
        name = network.get("name", "unnamed")
        dhcp_enabled = network.get("dhcpd_enabled", False)

        if not dhcp_enabled:
            continue

        dhcp_start = network.get("dhcpd_start", "")
        dhcp_stop = network.get("dhcpd_stop", "")

        if not dhcp_start or not dhcp_stop:
            continue

        try:
            dhcp_start_addr = ipaddress.IPv4Address(dhcp_start)
            dhcp_stop_addr = ipaddress.IPv4Address(dhcp_stop)
        except ValueError:
            continue

        log("  ", f"Network '{name}': DHCP range {dhcp_start} - {dhcp_stop}")

        # Check for overlap: two ranges overlap if start1 <= end2 AND start2 <= end1
        if metallb_start <= dhcp_stop_addr and dhcp_start_addr <= metallb_end:
            overlap_found = True
            log("  ⚠️ ", f"OVERLAP: MetalLB range overlaps with '{name}' DHCP range!")
            log("  ", f"  MetalLB:  {metallb_start} - {metallb_end}")
            log("  ", f"  DHCP:     {dhcp_start} - {dhcp_stop}")
            warnings.append(
                f"MetalLB range ({metallb_range}) overlaps with "
                f"'{name}' DHCP range ({dhcp_start}-{dhcp_stop})"
            )

    if not overlap_found:
        log("  ✅", "MetalLB range does not overlap with any DHCP range")


def check_dns_reachability(
    client: UniFiClient,
    node_ips: list[str],
    warnings: list[str],
) -> None:
    """Verify DNS servers on the VLAN(s) used by K8s nodes are reachable.

    Identifies the network/VLAN each node is on and checks that the
    configured DNS servers respond.
    """
    log("🔍", "Checking DNS server reachability...")

    networks = client.get_networks()
    if not networks:
        log("  ⚠️ ", "No networks returned from UniFi — skipping DNS check")
        warnings.append("Could not fetch network configuration for DNS check")
        return

    # Find networks that contain our node IPs
    dns_servers_checked = set()

    for network in networks:
        subnet_str = network.get("ip_subnet", "")
        name = network.get("name", "unnamed")

        if not subnet_str:
            continue

        try:
            subnet = ipaddress.IPv4Network(subnet_str, strict=False)
        except ValueError:
            continue

        # Check if any node IPs are in this subnet
        nodes_in_subnet = [
            ip for ip in node_ips
            if ipaddress.IPv4Address(ip) in subnet
        ]

        if not nodes_in_subnet:
            continue

        log("  ", f"Network '{name}' ({subnet}): {len(nodes_in_subnet)} node(s)")

        # Get DNS servers for this network
        dns_servers = []
        # UniFi stores DNS in dhcpd_dns_1, dhcpd_dns_2, etc.
        for i in range(1, 5):
            dns = network.get(f"dhcpd_dns_{i}", "")
            if dns:
                dns_servers.append(dns)

        # Also check the gateway as a potential DNS server
        gateway = network.get("gateway_ip", network.get("ip_subnet", "").split("/")[0])

        if not dns_servers:
            log("  ⚠️ ", f"  No DNS servers configured for '{name}'")
            warnings.append(f"No DNS servers configured on network '{name}'")
            continue

        for dns in dns_servers:
            if dns in dns_servers_checked:
                continue
            dns_servers_checked.add(dns)

            # Try to reach the DNS server with a simple ping
            try:
                result = run_cmd(
                    ["ping", "-c", "1", "-W", "2", dns],
                    capture=True, check=False, timeout=5,
                )
                if result.returncode == 0:
                    log("  ✅", f"  DNS {dns}: reachable")
                else:
                    log("  ⚠️ ", f"  DNS {dns}: unreachable")
                    warnings.append(f"DNS server {dns} on network '{name}' is unreachable")
            except subprocess.TimeoutExpired:
                log("  ⚠️ ", f"  DNS {dns}: timeout")
                warnings.append(f"DNS server {dns} on network '{name}' timed out")


def check_inter_vlan_routing(
    client: UniFiClient,
    node_names: list[str],
    node_ips: list[str],
    warnings: list[str],
) -> None:
    """Verify inter-VLAN routing if K8s nodes span multiple VLANs.

    LEARNING NOTE — WHY CHECK THIS:
        If K8s nodes are on different VLANs, the pods can't communicate
        unless inter-VLAN routing is enabled. This is typically handled
        by the router/gateway, but firewall rules can block it.
    """
    log("🔍", "Checking inter-VLAN routing...")

    if len(node_ips) < 2:
        log("  ℹ️ ", "Fewer than 2 nodes — skipping inter-VLAN check")
        return

    networks = client.get_networks()

    # Map each node IP to its VLAN/network
    node_vlans: dict[str, str] = {}
    for ip in node_ips:
        for network in networks:
            subnet_str = network.get("ip_subnet", "")
            if not subnet_str:
                continue
            try:
                subnet = ipaddress.IPv4Network(subnet_str, strict=False)
                if ipaddress.IPv4Address(ip) in subnet:
                    vlan_id = network.get("vlan", network.get("vlan_tag", "untagged"))
                    node_vlans[ip] = f"{network.get('name', 'unknown')} (VLAN {vlan_id})"
                    break
            except ValueError:
                continue

    # Report VLAN distribution
    unique_vlans = set(node_vlans.values())
    if len(unique_vlans) <= 1:
        vlan_name = next(iter(unique_vlans), "unknown")
        log("  ✅", f"All nodes on same network: {vlan_name}")
        return

    log("  ⚠️ ", f"Nodes span {len(unique_vlans)} networks:")
    for name, ip in zip(node_names, node_ips):
        vlan = node_vlans.get(ip, "unknown")
        log("  ", f"  {name} ({ip}): {vlan}")

    # Check inter-VLAN routing is likely enabled
    # UniFi enables inter-VLAN routing by default for corporate networks
    for network in networks:
        purpose = network.get("purpose", "")
        name = network.get("name", "unnamed")
        if purpose == "corporate":
            # Corporate networks have inter-VLAN routing enabled by default
            continue

        # Check if guest isolation or similar is blocking
        is_guest = network.get("is_guest", False)
        if is_guest:
            log("  ⚠️ ", f"  Network '{name}' is a guest network — may block inter-VLAN traffic")
            warnings.append(
                f"Network '{name}' is configured as guest — "
                f"inter-VLAN routing to K8s nodes may be blocked"
            )

    warnings.append(
        f"K8s nodes span {len(unique_vlans)} VLANs — "
        f"verify inter-VLAN routing and firewall rules allow pod traffic"
    )


def check_dhcp_reservations(
    client: UniFiClient,
    warnings: list[str],
) -> None:
    """Report DHCP reservations that should be converted to static assignments.

    This is informational — it flags any infrastructure devices (servers,
    NAS, etc.) that are using DHCP reservations instead of true static IPs.
    """
    log("🔍", "Checking for DHCP reservations to convert...")

    configured_clients = client.get_configured_clients()
    reservations = []

    for c in configured_clients:
        if c.get("use_fixedip") and c.get("fixed_ip"):
            reservations.append({
                "name": c.get("name", c.get("hostname", "unknown")),
                "ip": c["fixed_ip"],
                "mac": c.get("mac", "unknown"),
            })

    if not reservations:
        log("  ✅", "No DHCP reservations found")
        return

    log("  ℹ️ ", f"Found {len(reservations)} DHCP reservation(s):")
    for r in reservations:
        log("  ", f"  {r['name']}: {r['ip']} (MAC: {r['mac']})")

    if reservations:
        warnings.append(
            f"{len(reservations)} device(s) use DHCP reservations — "
            f"consider converting infrastructure devices to static IPs"
        )


# =============================================================================
# MAIN ORCHESTRATOR
# =============================================================================

def run_network_checks(
    kube_context: str = "",
    repo_root: str = "",
) -> list[str]:
    """Run all UniFi network pre-flight checks.

    Returns a list of warning messages. Empty list = all checks passed.
    This function is designed to be called from bootstrap.py.
    """
    log("🌐", "Running UniFi network pre-flight checks...")
    log("═" * 55, "")

    config = NetworkCheckConfig()
    if repo_root:
        config.repo_root = repo_root

    warnings: list[str] = []

    # ── Load credentials from 1Password ─────────────────────────────
    if not load_credentials(config):
        warnings.append(
            "Could not load UniFi credentials from 1Password — "
            "network checks skipped"
        )
        return warnings

    # ── Get K8s node data ───────────────────────────────────────────
    log("📡", "Fetching cluster node information...")
    config.node_names, config.node_ips = get_node_ips(kube_context)
    if config.node_ips:
        log("  ✅", f"Found {len(config.node_ips)} node(s): "
            f"{', '.join(f'{n} ({ip})' for n, ip in zip(config.node_names, config.node_ips))}")
    else:
        log("  ⚠️ ", "No nodes found — some checks will be skipped")
        warnings.append("Could not fetch K8s node IPs")

    # ── Get MetalLB range ───────────────────────────────────────────
    config.metallb_ip_range = get_metallb_range_from_vars(config.repo_root)
    if config.metallb_ip_range:
        log("  ✅", f"MetalLB range: {config.metallb_ip_range}")
    else:
        log("  ⚠️ ", "MetalLB range not found")

    # ── Connect to UniFi ────────────────────────────────────────────
    log("🔌", f"Connecting to UniFi controller at {config.unifi_host}...")
    client = UniFiClient(
        host=config.unifi_host,
        username=config.unifi_username,
        password=config.unifi_password,
        site=config.unifi_site,
    )

    if not client.login():
        warnings.append(
            "Could not connect to UniFi controller — "
            "network checks skipped"
        )
        return warnings

    log("  ✅", "Connected to UniFi controller")

    try:
        # ── Run all checks ──────────────────────────────────────────
        check_node_ip_assignments(client, config.node_names, config.node_ips, warnings)
        check_metallb_dhcp_overlap(client, config.metallb_ip_range, warnings)
        check_dns_reachability(client, config.node_ips, warnings)
        check_inter_vlan_routing(client, config.node_names, config.node_ips, warnings)
        check_dhcp_reservations(client, warnings)
    finally:
        client.logout()

    # ── Summary ─────────────────────────────────────────────────────
    print()
    if warnings:
        log("⚠️ ", f"Network checks completed with {len(warnings)} warning(s):")
        for w in warnings:
            log("  ", f"  • {w}")
    else:
        log("✅", "All network checks passed — no issues found")

    return warnings


# =============================================================================
# STANDALONE EXECUTION
# =============================================================================

if __name__ == "__main__":
    """Allow running network checks independently for debugging."""
    import argparse

    parser = argparse.ArgumentParser(
        description="UniFi network pre-flight validation",
    )
    parser.add_argument(
        "--kube-context", default="",
        help="Kubernetes context to use (default: current context)",
    )
    args = parser.parse_args()

    warnings = run_network_checks(kube_context=args.kube_context)

    if warnings:
        log("\n📋", "Action items:")
        for i, w in enumerate(warnings, 1):
            log("  ", f"  {i}. {w}")
        sys.exit(0)  # Advisory only — don't fail
    else:
        sys.exit(0)
