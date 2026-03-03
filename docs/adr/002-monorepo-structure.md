# ADR-002: Monorepo for All Infrastructure

## Status
Superseded by [ADR-009](009-microservice-repo-migration.md)

## Date
2026-02-13

## Context
Infrastructure spans Kubernetes manifests (Flux), cloud resources (Terraform),
GitHub Actions workflows, and documentation. Need to decide between one repo
or many.

## Decision
Single monorepo (`diixtra-forge`) with path-based CI triggers.

## Rationale
- Single source of truth — one PR can update DNS and the Ingress that depends on it
- Path-filtered GitHub Actions scope pipelines correctly
- Small team (solo) — polyrepo coordination overhead is wasted
- Atomic commits across layers (Terraform + Kubernetes changes together)

## Migration Path
Split into polyrepo if: team exceeds ~5 engineers, or different layers need
isolated access controls, or CI pipeline times become unacceptable.

## Superseded By
ADR-009 (Multi-Repo Migration, 2026-02-27). The monorepo is being migrated
to a purpose-specific multi-repo structure.
