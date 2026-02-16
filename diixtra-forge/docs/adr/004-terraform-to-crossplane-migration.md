# ADR-004: Terraform → Crossplane Migration Path

## Status
Accepted

## Date
2026-02-13

## Context
Cloud resources (DNS, future AWS) currently managed by Terraform via GitHub
Actions. Crossplane can manage the same resources as Kubernetes CRDs, aligning
with the "everything through the K8s API" philosophy.

## Decision
Start with Terraform, migrate to Crossplane incrementally.

## Migration Steps
1. Install Crossplane and relevant providers on homelab cluster
2. Import existing Terraform-managed resources one at a time
3. Verify Crossplane reconciliation matches Terraform state
4. Remove Terraform config for migrated resources
5. Keep Terraform for any resources that shouldn't depend on cluster health
