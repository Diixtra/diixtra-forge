# ADR-009: Migrate from Monorepo to Multi-Repo Microservice Architecture

## Status
Proposed

## Date
2026-02-27

## Context
ADR-002 established the monorepo (`diixtra-forge`) as the right choice for a solo
operator. The platform has since grown to include Backstage IDP, MCP servers,
Packer golden images, and multiple CI/CD pipelines — all in one repo.

Two drivers now favour splitting:
1. **AI-assisted development** — AI agents work best on focused, self-contained
   repos with clear boundaries. A monorepo with mixed Kubernetes YAML, TypeScript,
   HCL, and Packer templates increases context noise and error rates.
2. **Independent release cadence** — Backstage builds and MCP server images have
   no reason to be gated by infrastructure manifest changes, and vice versa.

## Decision
Split the monorepo into **purpose-specific repositories** while keeping the
GitOps control plane (`diixtra-forge`) as the deployment source of truth.

## Supersedes
ADR-002 (Monorepo for All Infrastructure). The migration path trigger cited in
ADR-002 ("team exceeds ~5 engineers, or different layers need isolated access
controls") now includes "AI agents acting as parallel contributors."
