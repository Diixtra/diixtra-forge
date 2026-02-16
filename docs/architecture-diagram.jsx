import { useState } from "react";

const COLORS = {
  bg: "#0a0e17",
  bgCard: "#111827",
  bgCardHover: "#1a2332",
  border: "#1e293b",
  borderActive: "#3b82f6",
  text: "#e2e8f0",
  textMuted: "#64748b",
  textDim: "#475569",
  accent: "#3b82f6",
  accentGlow: "rgba(59,130,246,0.15)",
  green: "#10b981",
  greenGlow: "rgba(16,185,129,0.15)",
  amber: "#f59e0b",
  amberGlow: "rgba(245,158,11,0.15)",
  purple: "#8b5cf6",
  purpleGlow: "rgba(139,92,246,0.15)",
  red: "#ef4444",
  redGlow: "rgba(239,68,68,0.15)",
  cyan: "#06b6d4",
  cyanGlow: "rgba(6,182,212,0.15)",
  pink: "#ec4899",
  pinkGlow: "rgba(236,72,153,0.15)",
};

const FLOWS = {
  request: {
    label: "Request Flow",
    color: COLORS.cyan,
    glow: COLORS.cyanGlow,
    icon: "→",
    steps: [
      "Browser requests https://test.lab.kazie.co.uk",
      "Unifi DNS resolves to MetalLB VIP (10.2.0.200-210)",
      "MetalLB L2 ARP routes to Caddy pod",
      "Caddy terminates TLS (Let's Encrypt via Cloudflare DNS-01)",
      "Caddy reverse-proxies to backend Service",
      "Backend pod responds through the chain",
    ],
  },
  gitops: {
    label: "GitOps Flow",
    color: COLORS.accent,
    glow: COLORS.accentGlow,
    icon: "⟳",
    steps: [
      "Developer pushes to github.com/*/kazie-infrastructure",
      "Flux source-controller detects new commit (1min poll)",
      "kustomize-controller builds overlays for homelab cluster",
      "Dependency chain: infrastructure → platform → apps",
      "helm-controller upgrades HelmReleases if chart versions changed",
      "Health checks gate each layer before the next deploys",
    ],
  },
  secrets: {
    label: "Secrets Flow",
    color: COLORS.purple,
    glow: COLORS.purpleGlow,
    icon: "🔐",
    steps: [
      "Bootstrap: op-service-account-token Secret created manually (chicken-egg)",
      "Flux deploys 1Password Operator HelmRelease",
      "Operator reads OnePasswordItem CRDs from Git",
      "Operator syncs items from 1Password vault → K8s Secrets",
      "Pods reference secrets via secretKeyRef in env vars",
      "Secrets auto-rotate when updated in 1Password",
    ],
  },
  storage: {
    label: "Storage Flow",
    color: COLORS.green,
    glow: COLORS.greenGlow,
    icon: "💾",
    steps: [
      "Workload creates PersistentVolumeClaim with StorageClass",
      "democratic-csi controller intercepts the PVC request",
      "Controller calls TrueNAS API at 10.2.0.232",
      "TrueNAS creates ZFS child dataset + NFS share (or iSCSI zvol)",
      "democratic-csi node agent (DaemonSet) mounts into pod",
      "On PVC delete: TrueNAS cleans up dataset and share",
    ],
  },
  autoupdate: {
    label: "Auto-Update Flow",
    color: COLORS.amber,
    glow: COLORS.amberGlow,
    icon: "⬆",
    steps: [
      'Helm charts: version "*" — source-controller checks every 1h',
      "Container images: image-reflector-controller scans registries every 5m",
      "image-automation-controller commits new digests to Git",
      "Renovate Bot (GitHub Actions) PRs for Actions/Terraform/Flux versions",
      "All Renovate PRs auto-merge (lab config, no review needed)",
      "Every change flows through Git — full audit trail preserved",
    ],
  },
};

const Node = ({ x, y, w, h, label, sublabel, icon, color, glow, children, small, onClick }) => {
  const [hovered, setHovered] = useState(false);
  return (
    <g
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onClick={onClick}
      style={{ cursor: onClick ? "pointer" : "default" }}
    >
      <rect
        x={x} y={y} width={w} height={h} rx={8}
        fill={hovered ? COLORS.bgCardHover : COLORS.bgCard}
        stroke={hovered ? color || COLORS.borderActive : COLORS.border}
        strokeWidth={hovered ? 1.5 : 1}
        filter={hovered && glow ? `drop-shadow(0 0 8px ${color})` : "none"}
      />
      {icon && (
        <text x={x + 12} y={y + (small ? 18 : 22)} fontSize={small ? 13 : 15} fill={color || COLORS.text}>
          {icon}
        </text>
      )}
      <text
        x={x + (icon ? 30 : 12)} y={y + (small ? 18 : 22)}
        fontSize={small ? 11 : 13} fontWeight="600" fill={color || COLORS.text}
        fontFamily="'JetBrains Mono', 'SF Mono', 'Fira Code', monospace"
      >
        {label}
      </text>
      {sublabel && (
        <text
          x={x + (icon ? 30 : 12)} y={y + (small ? 32 : 38)}
          fontSize={small ? 9 : 10} fill={COLORS.textMuted}
          fontFamily="'JetBrains Mono', 'SF Mono', monospace"
        >
          {sublabel}
        </text>
      )}
      {children}
    </g>
  );
};

const Arrow = ({ x1, y1, x2, y2, color, dashed, label }) => (
  <g>
    <defs>
      <marker id={`ah-${color?.replace('#','')}`} markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
        <polygon points="0 0, 8 3, 0 6" fill={color || COLORS.textMuted} />
      </marker>
    </defs>
    <line
      x1={x1} y1={y1} x2={x2} y2={y2}
      stroke={color || COLORS.textMuted} strokeWidth={1.2}
      strokeDasharray={dashed ? "4,3" : "none"}
      markerEnd={`url(#ah-${color?.replace('#','')})`}
      opacity={0.7}
    />
    {label && (
      <text
        x={(x1+x2)/2} y={(y1+y2)/2 - 5}
        fontSize={8} fill={color || COLORS.textDim} textAnchor="middle"
        fontFamily="'JetBrains Mono', monospace"
      >
        {label}
      </text>
    )}
  </g>
);

const LayerLabel = ({ x, y, label, color }) => (
  <g>
    <rect x={x} y={y} width={label.length * 8 + 16} height={20} rx={4} fill={color} opacity={0.15} />
    <text x={x + 8} y={y + 14} fontSize={10} fontWeight="700" fill={color}
      fontFamily="'JetBrains Mono', monospace" letterSpacing="0.5">
      {label}
    </text>
  </g>
);

const FlowPanel = ({ flow }) => (
  <div style={{
    background: COLORS.bgCard, border: `1px solid ${flow.color}33`,
    borderRadius: 8, padding: "16px 20px", marginTop: 12,
    boxShadow: `0 0 20px ${flow.glow}`,
  }}>
    <div style={{
      fontSize: 14, fontWeight: 700, color: flow.color, marginBottom: 10,
      fontFamily: "'JetBrains Mono', monospace",
      display: "flex", alignItems: "center", gap: 8,
    }}>
      <span style={{ fontSize: 18 }}>{flow.icon}</span> {flow.label}
    </div>
    <ol style={{ margin: 0, paddingLeft: 20 }}>
      {flow.steps.map((s, i) => (
        <li key={i} style={{
          color: COLORS.text, fontSize: 12, marginBottom: 6, lineHeight: 1.5,
          fontFamily: "'JetBrains Mono', monospace",
        }}>
          <span style={{ color: flow.color, fontWeight: 600 }}>{i + 1}.</span>{" "}
          {s}
        </li>
      ))}
    </ol>
  </div>
);

export default function ArchitectureDiagram() {
  const [activeFlow, setActiveFlow] = useState(null);

  return (
    <div style={{
      background: COLORS.bg, minHeight: "100vh", padding: "24px 20px",
      fontFamily: "'JetBrains Mono', 'SF Mono', 'Fira Code', monospace",
      color: COLORS.text,
    }}>
      {/* Header */}
      <div style={{ textAlign: "center", marginBottom: 8 }}>
        <h1 style={{
          fontSize: 22, fontWeight: 800, color: COLORS.text, margin: 0,
          letterSpacing: "-0.5px",
        }}>
          kazie-infrastructure
        </h1>
        <p style={{ fontSize: 11, color: COLORS.textMuted, margin: "4px 0 0" }}>
          Homelab GitOps Stack · Flux CD · TrueNAS · 1Password · Cloudflare
        </p>
      </div>

      {/* Flow selector */}
      <div style={{
        display: "flex", gap: 6, justifyContent: "center", flexWrap: "wrap",
        marginBottom: 16,
      }}>
        {Object.entries(FLOWS).map(([key, flow]) => (
          <button
            key={key}
            onClick={() => setActiveFlow(activeFlow === key ? null : key)}
            style={{
              background: activeFlow === key ? flow.color + "22" : COLORS.bgCard,
              border: `1px solid ${activeFlow === key ? flow.color : COLORS.border}`,
              borderRadius: 6, padding: "6px 12px", cursor: "pointer",
              color: activeFlow === key ? flow.color : COLORS.textMuted,
              fontSize: 10, fontWeight: 600,
              fontFamily: "'JetBrains Mono', monospace",
              transition: "all 0.2s",
            }}
          >
            {flow.icon} {flow.label}
          </button>
        ))}
      </div>

      {/* Main SVG Diagram */}
      <div style={{
        background: COLORS.bgCard, border: `1px solid ${COLORS.border}`,
        borderRadius: 12, padding: 12, overflow: "auto",
      }}>
        <svg viewBox="0 0 980 720" width="100%" style={{ display: "block" }}>
          {/* Background grid */}
          <defs>
            <pattern id="grid" width="20" height="20" patternUnits="userSpaceOnUse">
              <path d="M 20 0 L 0 0 0 20" fill="none" stroke={COLORS.border} strokeWidth="0.3" opacity="0.3" />
            </pattern>
          </defs>
          <rect width="980" height="720" fill="url(#grid)" />

          {/* ═══ EXTERNAL SERVICES (top) ═══ */}
          <LayerLabel x={10} y={8} label="EXTERNAL SERVICES" color={COLORS.pink} />

          <Node x={20} y={32} w={145} h={50} label="GitHub" sublabel="kazie-infrastructure repo" icon="⊙" color={COLORS.pink} glow={COLORS.pinkGlow} small />
          <Node x={175} y={32} w={145} h={50} label="1Password" sublabel="Homela vault" icon="🔑" color={COLORS.pink} glow={COLORS.pinkGlow} small />
          <Node x={330} y={32} w={145} h={50} label="Cloudflare" sublabel="kazie.co.uk DNS + API" icon="☁" color={COLORS.pink} glow={COLORS.pinkGlow} small />
          <Node x={485} y={32} w={145} h={50} label="Let's Encrypt" sublabel="TLS certificates" icon="🔒" color={COLORS.pink} glow={COLORS.pinkGlow} small />
          <Node x={640} y={32} w={145} h={50} label="Grafana Cloud" sublabel="Metrics/logs backend" icon="📊" color={COLORS.pink} glow={COLORS.pinkGlow} small />
          <Node x={795} y={32} w={165} h={50} label="Helm Registries" sublabel="Charts (GHCR, artifacts)" icon="📦" color={COLORS.pink} glow={COLORS.pinkGlow} small />

          {/* ═══ GITOPS CONTROL PLANE ═══ */}
          <LayerLabel x={10} y={98} label="GITOPS CONTROL PLANE — flux-system" color={COLORS.accent} />

          <Node x={20} y={122} w={150} h={55} label="source-ctrl" sublabel="Git/Helm/OCI polling" icon="📡" color={COLORS.accent} glow={COLORS.accentGlow} small />
          <Node x={180} y={122} w={150} h={55} label="kustomize-ctrl" sublabel="Overlay builds + SSA" icon="🔧" color={COLORS.accent} glow={COLORS.accentGlow} small />
          <Node x={340} y={122} w={150} h={55} label="helm-ctrl" sublabel="HelmRelease lifecycle" icon="⎈" color={COLORS.accent} glow={COLORS.accentGlow} small />
          <Node x={500} y={122} w={150} h={55} label="notification-ctrl" sublabel="Alerts & events" icon="🔔" color={COLORS.accent} glow={COLORS.accentGlow} small />
          <Node x={660} y={122} w={150} h={55} label="image-reflector" sublabel="Registry scanning (5m)" icon="🔍" color={COLORS.amber} glow={COLORS.amberGlow} small />
          <Node x={820} y={122} w={140} h={55} label="image-auto" sublabel="Git commit updates" icon="✏" color={COLORS.amber} glow={COLORS.amberGlow} small />

          {/* Arrows: External → Flux */}
          <Arrow x1={92} y1={82} x2={92} y2={122} color={COLORS.accent} label="poll" />
          <Arrow x1={877} y1={82} x2={877} y2={122} color={COLORS.amber} label="fetch" />

          {/* ═══ INFRASTRUCTURE LAYER ═══ */}
          <LayerLabel x={10} y={198} label="INFRASTRUCTURE LAYER — deploys first (no dependencies)" color={COLORS.green} />

          <Node x={20} y={222} w={185} h={80} label="1Password Operator" sublabel="HelmRelease v*" icon="🔑" color={COLORS.green} glow={COLORS.greenGlow}>
            <text x={32} y={280} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">namespace: onepassword-system</text>
            <text x={32} y={292} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">mode: Service Account</text>
          </Node>

          <Node x={215} y={222} w={185} h={80} label="MetalLB" sublabel="HelmRelease v* · L2 mode" icon="🌐" color={COLORS.green} glow={COLORS.greenGlow}>
            <text x={227} y={280} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">pool: 10.2.0.200-210</text>
            <text x={227} y={292} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">namespace: metallb-system</text>
          </Node>

          <Node x={410} y={222} w={185} h={80} label="Caddy" sublabel="Reverse proxy + TLS" icon="🔒" color={COLORS.green} glow={COLORS.greenGlow}>
            <text x={422} y={280} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">caddy-cloudflare image</text>
            <text x={422} y={292} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">DNS-01 challenge</text>
          </Node>

          <Node x={605} y={222} w={185} h={80} label="democratic-csi" sublabel="NFS + iSCSI drivers" icon="💾" color={COLORS.green} glow={COLORS.greenGlow}>
            <text x={617} y={280} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">TrueNAS API: 10.2.0.232</text>
            <text x={617} y={292} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">StorageClass: auto-provision</text>
          </Node>

          <Node x={800} y={222} w={160} h={80} label="Flux Addons" sublabel="Helm repos + Image Auto" icon="🧩" color={COLORS.green} glow={COLORS.greenGlow}>
            <text x={812} y={280} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">HelmRepository sources</text>
            <text x={812} y={292} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">ImageUpdateAutomation</text>
          </Node>

          {/* Arrows: Flux → Infrastructure */}
          <Arrow x1={255} y1={177} x2={112} y2={222} color={COLORS.accent} />
          <Arrow x1={255} y1={177} x2={307} y2={222} color={COLORS.accent} />
          <Arrow x1={415} y1={177} x2={502} y2={222} color={COLORS.accent} />
          <Arrow x1={415} y1={177} x2={697} y2={222} color={COLORS.accent} />

          {/* 1Password → Caddy secret */}
          <Arrow x1={205} y1={262} x2={410} y2={262} color={COLORS.purple} dashed label="syncs cloudflare-api-token" />

          {/* ═══ PLATFORM LAYER ═══ */}
          <LayerLabel x={10} y={322} label="PLATFORM LAYER — dependsOn: infrastructure" color={COLORS.purple} />

          <Node x={20} y={346} w={220} h={80} label="Kyverno" sublabel="HelmRelease v* · Policy engine" icon="🛡" color={COLORS.purple} glow={COLORS.purpleGlow}>
            <text x={32} y={404} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">require-resource-limits (Audit)</text>
            <text x={32} y={416} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">require-standard-labels (Audit)</text>
          </Node>

          <Node x={250} y={346} w={220} h={80} label="Grafana Alloy" sublabel="HelmRelease v* · DaemonSet" icon="📊" color={COLORS.purple} glow={COLORS.purpleGlow}>
            <text x={262} y={404} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">OpenTelemetry collection</text>
            <text x={262} y={416} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">→ Grafana Cloud backend</text>
          </Node>

          {/* Dependency arrow */}
          <Arrow x1={350} y1={302} x2={350} y2={346} color={COLORS.purple} dashed label="dependsOn: infrastructure" />

          {/* ═══ APPS LAYER ═══ */}
          <LayerLabel x={10} y={446} label="APPS LAYER — dependsOn: platform" color={COLORS.red} />

          <Node x={20} y={470} w={220} h={55} label="Future Diixtra Services" sublabel="App workloads deploy here" icon="🚀" color={COLORS.red} glow={COLORS.redGlow} small />
          <Node x={250} y={470} w={220} h={55} label="PVCs → democratic-csi" sublabel="Auto-provisioned NFS/iSCSI" icon="💾" color={COLORS.red} glow={COLORS.redGlow} small />

          <Arrow x1={200} y1={426} x2={130} y2={470} color={COLORS.red} dashed label="dependsOn: platform" />
          {/* PVC arrow to democratic-csi */}
          <Arrow x1={470} y1={497} x2={697} y2={302} color={COLORS.green} dashed label="PVC → StorageClass" />

          {/* ═══ KUBERNETES NODES ═══ */}
          <LayerLabel x={540} y={346} label="KUBERNETES CLUSTER — kubeadm + Flannel CNI" color={COLORS.cyan} />

          <Node x={540} y={370} w={140} h={65} label="kaz-k8-1" sublabel="Control plane · Debian" icon="⬡" color={COLORS.cyan} glow={COLORS.cyanGlow} small>
            <text x={552} y={418} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">etcd + API server</text>
          </Node>
          <Node x={690} y={370} w={140} h={65} label="k8-worker-1" sublabel="Worker · amd64" icon="⬡" color={COLORS.cyan} glow={COLORS.cyanGlow} small>
            <text x={702} y={418} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">nfs-common + open-iscsi</text>
          </Node>
          <Node x={840} y={370} w={120} h={65} label="pi4 / pi5" sublabel="Workers · ARM64" icon="⬡" color={COLORS.cyan} glow={COLORS.cyanGlow} small>
            <text x={852} y={418} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">Raspberry Pi</text>
          </Node>

          {/* ═══ STORAGE LAYER ═══ */}
          <LayerLabel x={540} y={455} label="STORAGE — TrueNAS SCALE · 10.2.0.232" color={COLORS.green} />

          <Node x={540} y={478} w={200} h={70} label="NFS StorageClass" sublabel="truenas-nfs-csi (default)" icon="📁" color={COLORS.green} glow={COLORS.greenGlow} small>
            <text x={552} y={528} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">ReadWriteMany · file storage</text>
            <text x={552} y={539} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">pool/k8s/nfs/volumes</text>
          </Node>

          <Node x={750} y={478} w={210} h={70} label="iSCSI StorageClass" sublabel="truenas-iscsi-csi" icon="💿" color={COLORS.green} glow={COLORS.greenGlow} small>
            <text x={762} y={528} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">ReadWriteOnce · block storage</text>
            <text x={762} y={539} fontSize={8} fill={COLORS.textDim} fontFamily="monospace">pool/k8s/iscsi/volumes</text>
          </Node>

          {/* democratic-csi → TrueNAS */}
          <Arrow x1={697} y1={302} x2={640} y2={478} color={COLORS.green} label="TrueNAS HTTP API" />

          {/* ═══ NETWORK LAYER ═══ */}
          <LayerLabel x={10} y={565} label="NETWORK — Kaznet VLAN · 10.2.0.0/24 · Unifi" color={COLORS.cyan} />

          <Node x={20} y={588} w={180} h={55} label="Unifi Router" sublabel="DNS: *.lab.kazie.co.uk" icon="📡" color={COLORS.cyan} glow={COLORS.cyanGlow} small />
          <Node x={210} y={588} w={180} h={55} label="MetalLB VIPs" sublabel="10.2.0.200 — 10.2.0.210" icon="🌐" color={COLORS.cyan} glow={COLORS.cyanGlow} small />
          <Node x={400} y={588} w={180} h={55} label="Flannel VXLAN" sublabel="Pod network 10.244.0.0/16" icon="🔗" color={COLORS.cyan} glow={COLORS.cyanGlow} small />
          <Node x={590} y={588} w={180} h={55} label="CoreDNS" sublabel="cluster.local resolution" icon="🏷" color={COLORS.cyan} glow={COLORS.cyanGlow} small />
          <Node x={780} y={588} w={180} h={55} label="TrueNAS NAS" sublabel="10.2.0.232 · NFS + iSCSI" icon="💾" color={COLORS.cyan} glow={COLORS.cyanGlow} small />

          {/* ═══ CI/CD LAYER ═══ */}
          <LayerLabel x={10} y={660} label="CI/CD — GitHub Actions" color={COLORS.amber} />

          <Node x={20} y={682} w={190} h={30} label="flux-validate.yaml" icon="✓" color={COLORS.amber} small />
          <Node x={220} y={682} w={210} h={30} label="terraform-cloudflare.yaml" icon="⛅" color={COLORS.amber} small />
          <Node x={440} y={682} w={160} h={30} label="renovate.yaml" icon="⬆" color={COLORS.amber} small />
          <Node x={610} y={682} w={200} h={30} label="Auto-merge all PRs" icon="✔" color={COLORS.amber} small />

          {/* ═══ LEGEND ═══ */}
          <text x={830} y={675} fontSize={9} fill={COLORS.textDim} fontFamily="monospace">── solid = data flow</text>
          <text x={830} y={688} fontSize={9} fill={COLORS.textDim} fontFamily="monospace">╌╌ dashed = dependency</text>
          <text x={830} y={701} fontSize={9} fill={COLORS.textDim} fontFamily="monospace">v* = auto-update latest</text>
        </svg>
      </div>

      {/* Flow detail panel */}
      {activeFlow && <FlowPanel flow={FLOWS[activeFlow]} />}

      {/* Stats bar */}
      <div style={{
        display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(140px, 1fr))",
        gap: 8, marginTop: 16,
      }}>
        {[
          { label: "Flux Controllers", value: "6", color: COLORS.accent },
          { label: "Infrastructure", value: "5 components", color: COLORS.green },
          { label: "Platform", value: "2 components", color: COLORS.purple },
          { label: "K8s Nodes", value: "4 (mixed arch)", color: COLORS.cyan },
          { label: "StorageClasses", value: "2 (NFS+iSCSI)", color: COLORS.green },
          { label: "Auto-Update", value: "3 mechanisms", color: COLORS.amber },
        ].map((s, i) => (
          <div key={i} style={{
            background: COLORS.bgCard, border: `1px solid ${COLORS.border}`,
            borderRadius: 8, padding: "10px 12px", textAlign: "center",
          }}>
            <div style={{ fontSize: 18, fontWeight: 800, color: s.color }}>{s.value}</div>
            <div style={{ fontSize: 9, color: COLORS.textMuted, marginTop: 2 }}>{s.label}</div>
          </div>
        ))}
      </div>

      {/* Component inventory */}
      <div style={{
        background: COLORS.bgCard, border: `1px solid ${COLORS.border}`,
        borderRadius: 12, padding: 16, marginTop: 16,
      }}>
        <h3 style={{ fontSize: 13, color: COLORS.text, margin: "0 0 12px", fontWeight: 700 }}>
          Complete Component Inventory
        </h3>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))", gap: 12 }}>
          {[
            {
              layer: "Infrastructure", color: COLORS.green, items: [
                "1Password Operator — Secret sync from vault",
                "MetalLB — L2 LoadBalancer (10.2.0.200-210)",
                "Caddy — Reverse proxy + auto-TLS",
                "democratic-csi NFS — File storage provisioner",
                "democratic-csi iSCSI — Block storage provisioner",
                "Flux Addons — HelmRepos + ImageAutomation",
              ]
            },
            {
              layer: "Platform", color: COLORS.purple, items: [
                "Kyverno — Policy engine (Audit mode)",
                "Kyverno Policies — Labels, limits, no-privileged",
                "Grafana Alloy — OTel collection DaemonSet",
              ]
            },
            {
              layer: "GitOps", color: COLORS.accent, items: [
                "source-controller — Git/Helm/OCI sync",
                "kustomize-controller — Overlay reconciliation",
                "helm-controller — HelmRelease lifecycle",
                "notification-controller — Alerts/events",
                "image-reflector-controller — Registry scan",
                "image-automation-controller — Git commit",
              ]
            },
            {
              layer: "Auto-Updates", color: COLORS.amber, items: [
                'Helm: version: "*" (always latest)',
                "Images: Flux Image Automation (5m scan)",
                "CI/CD: Renovate Bot (6h, auto-merge)",
                "Caddy: digest pinning via ImagePolicy",
              ]
            },
          ].map((group, gi) => (
            <div key={gi}>
              <div style={{
                fontSize: 10, fontWeight: 700, color: group.color,
                marginBottom: 6, textTransform: "uppercase", letterSpacing: 1,
              }}>
                {group.layer}
              </div>
              {group.items.map((item, ii) => (
                <div key={ii} style={{
                  fontSize: 11, color: COLORS.textMuted, padding: "3px 0",
                  borderBottom: `1px solid ${COLORS.border}`,
                  display: "flex", alignItems: "center", gap: 6,
                }}>
                  <span style={{ color: group.color, fontSize: 8 }}>●</span> {item}
                </div>
              ))}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
