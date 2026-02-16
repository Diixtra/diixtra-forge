# ADR-003: Kyverno over Gatekeeper

## Status
Accepted

## Date
2026-02-13

## Context
Need a Kubernetes policy engine for enforcing standards (resource limits,
labels, security policies). Two main options: Kyverno and OPA Gatekeeper.

## Decision
Kyverno.

## Rationale
- Policies are written in YAML, not Rego (lower learning curve)
- Can mutate resources, not just validate (auto-add labels, inject sidecars)
- Generates audit reports as Kubernetes resources (queryable via kubectl)
- Starting in Audit mode — policies report violations without blocking
