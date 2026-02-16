# ADR-001: Flux CD over Argo CD

## Status
Accepted

## Date
2026-02-13

## Context
Need a GitOps operator for continuous delivery to multiple Kubernetes clusters.
The tool must integrate with GitHub Actions CI, support multi-cluster deployment,
and align with our IDP vision (Backstage, Crossplane, Kyverno).

## Options Considered
- **Flux CD** — Kubernetes-native CRDs, no UI, composable controllers
- **Argo CD** — UI-first, centralised management, Application-centric model
- **Fleet (Rancher)** — Built into Rancher Desktop, lightweight

## Decision
Flux CD.

## Rationale
- Everything is a Kubernetes CRD — aligns with "everything through the K8s API" IDP philosophy
- Each cluster self-manages independently (no single point of failure)
- Composable controllers work well as building blocks for a custom IDP CLI
- CLI-first workflow matches our automation-heavy approach
- Visual layer handled by Backstage + Grafana, not the GitOps tool

## Consequences
- No built-in deployment dashboard (accepted — Backstage fills this role)
- Team members need kubectl fluency (accepted — that's a skill we want)
- Kustomize is the primary templating mechanism (learning investment required)
