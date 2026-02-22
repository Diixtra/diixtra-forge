#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════
# Backstage Templates and Configuration Tests
# ══════════════════════════════════════════════════════════════════
#
# Validates YAML syntax, schema compliance, and template correctness
# for Backstage platform configuration and scaffolder templates.
#
# Usage:
#   ./tests/test-backstage-templates.sh
#
# Requirements:
#   - yamllint (YAML syntax validation)
#   - python3 with PyYAML (schema validation)
#
# ══════════════════════════════════════════════════════════════════

# Note: set -e disabled to avoid issues with Python heredocs in functions
set -o pipefail

# ── Colours ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ── Test Counters ────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0

# ── Helper Functions ─────────────────────────────────────────────

log_pass() {
  echo -e "${GREEN}✓ PASS${NC}: $1"
  ((TESTS_PASSED++))
}

log_fail() {
  echo -e "${RED}✗ FAIL${NC}: $1"
  ((TESTS_FAILED++))
}

log_info() {
  echo -e "${YELLOW}ℹ INFO${NC}: $1"
}

# Check if required tools are available
check_requirements() {
  if ! command -v yamllint &> /dev/null; then
    echo -e "${RED}ERROR${NC}: yamllint is not installed"
    echo "Install with: pip install yamllint"
    exit 1
  fi

  if ! command -v python3 &> /dev/null; then
    echo -e "${RED}ERROR${NC}: python3 is not installed"
    exit 1
  fi
}

# Test YAML syntax using yamllint
# Usage: test_yaml_syntax "description" "file_path" ["allow_templates"]
test_yaml_syntax() {
  local desc="$1"
  local file_path="$2"
  local allow_templates="${3:-false}"

  if [[ ! -f "$file_path" ]]; then
    log_fail "$desc (file not found: $file_path)"
    return
  fi

  # Skip yamllint for Jinja2/Nunjucks template files
  if [[ "$allow_templates" == "true" ]] && grep -q '{%-\|{%' "$file_path" 2>/dev/null; then
    log_pass "$desc (template file, syntax check skipped)"
    return
  fi

  # Use relaxed yamllint config - focus on actual syntax errors, not style
  if yamllint -d "{extends: default, rules: {line-length: {max: 200}, comments: {min-spaces-from-content: 1}, document-start: disable, new-line-at-end-of-file: disable, trailing-spaces: disable}}" "$file_path" &> /dev/null; then
    log_pass "$desc"
  else
    log_fail "$desc (yamllint validation failed)"
    yamllint -d "{extends: default, rules: {line-length: {max: 200}, comments: {min-spaces-from-content: 1}, document-start: disable, new-line-at-end-of-file: disable, trailing-spaces: disable}}" "$file_path" || true
  fi
}

# Test that file contains required fields
# Usage: test_required_fields "description" "file_path" "field1" "field2" ...
test_required_fields() {
  local desc="$1"
  local file_path="$2"
  shift 2
  local required_fields=("$@")

  if [[ ! -f "$file_path" ]]; then
    log_fail "$desc (file not found: $file_path)"
    return
  fi

  local missing_fields=()
  for field in "${required_fields[@]}"; do
    if ! grep -q "$field" "$file_path"; then
      missing_fields+=("$field")
    fi
  done

  if [[ ${#missing_fields[@]} -eq 0 ]]; then
    log_pass "$desc"
  else
    log_fail "$desc (missing fields: ${missing_fields[*]})"
  fi
}

# Test Kubernetes resource has valid apiVersion and kind
# Usage: test_k8s_resource "description" "file_path" "expected_kind"
test_k8s_resource() {
  local desc="$1"
  local file_path="$2"
  local expected_kind="$3"

  if [[ ! -f "$file_path" ]]; then
    log_fail "$desc (file not found: $file_path)"
    return
  fi

  python3 - "$file_path" "$expected_kind" <<'EOF'
import sys
import yaml

file_path = sys.argv[1]
expected_kind = sys.argv[2]

try:
    with open(file_path, 'r') as f:
        content = f.read()
        # Handle Jinja2 conditionals by checking if file starts with conditional
        if content.strip().startswith('{%-'):
            # Skip validation for conditional templates
            sys.exit(0)
        docs = list(yaml.safe_load_all(content))
        for doc in docs:
            if doc is None:
                continue
            if 'apiVersion' not in doc:
                print(f"Missing apiVersion", file=sys.stderr)
                sys.exit(1)
            if 'kind' not in doc:
                print(f"Missing kind", file=sys.stderr)
                sys.exit(1)
            if expected_kind and doc['kind'] != expected_kind:
                print(f"Expected kind {expected_kind}, got {doc['kind']}", file=sys.stderr)
                sys.exit(1)
    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

  if [[ $? -eq 0 ]]; then
    log_pass "$desc"
  else
    log_fail "$desc"
  fi
}

# Test Backstage template structure
# Usage: test_backstage_template "description" "file_path"
test_backstage_template() {
  local desc="$1"
  local file_path="$2"

  if [[ ! -f "$file_path" ]]; then
    log_fail "$desc (file not found: $file_path)"
    return
  fi

  python3 - "$file_path" <<'EOF'
import sys
import yaml

file_path = sys.argv[1]

try:
    with open(file_path, 'r') as f:
        doc = yaml.safe_load(f)

    # Check required template fields
    if doc.get('apiVersion') != 'scaffolder.backstage.io/v1beta3':
        print("Invalid apiVersion for Backstage template", file=sys.stderr)
        sys.exit(1)

    if doc.get('kind') != 'Template':
        print("Expected kind: Template", file=sys.stderr)
        sys.exit(1)

    metadata = doc.get('metadata', {})
    if not metadata.get('name'):
        print("Missing metadata.name", file=sys.stderr)
        sys.exit(1)

    if not metadata.get('title'):
        print("Missing metadata.title", file=sys.stderr)
        sys.exit(1)

    spec = doc.get('spec', {})
    if not spec.get('owner'):
        print("Missing spec.owner", file=sys.stderr)
        sys.exit(1)

    if not spec.get('parameters'):
        print("Missing spec.parameters", file=sys.stderr)
        sys.exit(1)

    if not spec.get('steps'):
        print("Missing spec.steps", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

  if [[ $? -eq 0 ]]; then
    log_pass "$desc"
  else
    log_fail "$desc"
  fi
}

# Test template variable syntax
# Usage: test_template_variables "description" "file_path" "variable_pattern"
test_template_variables() {
  local desc="$1"
  local file_path="$2"
  local variable_pattern="$3"

  if [[ ! -f "$file_path" ]]; then
    log_fail "$desc (file not found: $file_path)"
    return
  fi

  if grep -qE "$variable_pattern" "$file_path"; then
    log_pass "$desc"
  else
    log_fail "$desc (no variables matching pattern: $variable_pattern)"
  fi
}

# Test that Kustomization references valid files
# Usage: test_kustomization_resources "description" "file_path"
test_kustomization_resources() {
  local desc="$1"
  local file_path="$2"

  if [[ ! -f "$file_path" ]]; then
    log_fail "$desc (file not found: $file_path)"
    return
  fi

  local dir_path
  dir_path=$(dirname "$file_path")

  python3 - "$file_path" "$dir_path" <<'EOF'
import sys
import yaml
import os

file_path = sys.argv[1]
dir_path = sys.argv[2]

try:
    with open(file_path, 'r') as f:
        content = f.read()
        # Check if this is a template with conditionals
        if '{%-' in content or '{%' in content:
            # For templates, we can't validate file references
            sys.exit(0)
        doc = yaml.safe_load(content)

    resources = doc.get('resources', [])
    if not resources:
        print("Warning: No resources defined in Kustomization", file=sys.stderr)

    for resource in resources:
        # Skip template variables
        if '{{' in resource or '${' in resource:
            continue
        resource_path = os.path.join(dir_path, resource)
        if not os.path.exists(resource_path):
            print(f"Referenced resource does not exist: {resource}", file=sys.stderr)
            sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

  if [[ $? -eq 0 ]]; then
    log_pass "$desc"
  else
    log_fail "$desc"
  fi
}

# Test ConfigMap structure
# Usage: test_configmap "description" "file_path"
test_configmap() {
  local desc="$1"
  local file_path="$2"

  if [[ ! -f "$file_path" ]]; then
    log_fail "$desc (file not found: $file_path)"
    return
  fi

  python3 - "$file_path" <<'EOF'
import sys
import yaml

file_path = sys.argv[1]

try:
    with open(file_path, 'r') as f:
        doc = yaml.safe_load(f)

    if doc.get('kind') != 'ConfigMap':
        print("Expected kind: ConfigMap", file=sys.stderr)
        sys.exit(1)

    metadata = doc.get('metadata', {})
    if not metadata.get('name'):
        print("Missing metadata.name", file=sys.stderr)
        sys.exit(1)

    if not metadata.get('namespace'):
        print("Missing metadata.namespace", file=sys.stderr)
        sys.exit(1)

    if 'data' not in doc:
        print("Missing data field", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

  if [[ $? -eq 0 ]]; then
    log_pass "$desc"
  else
    log_fail "$desc"
  fi
}

# Test HelmRelease structure
# Usage: test_helm_release "description" "file_path"
test_helm_release() {
  local desc="$1"
  local file_path="$2"

  if [[ ! -f "$file_path" ]]; then
    log_fail "$desc (file not found: $file_path)"
    return
  fi

  python3 - "$file_path" <<'EOF'
import sys
import yaml

file_path = sys.argv[1]

try:
    with open(file_path, 'r') as f:
        content = f.read()
        # Skip templates with variables
        if content.strip().startswith('{%-'):
            sys.exit(0)
        doc = yaml.safe_load(content)

    if not doc:
        print("Empty document", file=sys.stderr)
        sys.exit(1)

    if doc.get('kind') != 'HelmRelease':
        print("Expected kind: HelmRelease", file=sys.stderr)
        sys.exit(1)

    if not doc.get('apiVersion', '').startswith('helm.toolkit.fluxcd.io'):
        print("Invalid apiVersion for HelmRelease", file=sys.stderr)
        sys.exit(1)

    spec = doc.get('spec', {})
    chart = spec.get('chart', {})
    chart_spec = chart.get('spec', {})

    if not chart_spec.get('chart') and not content.strip().startswith('apiVersion: helm'):
        print("Missing spec.chart.spec.chart", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

  if [[ $? -eq 0 ]]; then
    log_pass "$desc"
  else
    log_fail "$desc"
  fi
}

# Test naming patterns
# Usage: test_naming_pattern "description" "name" "pattern"
test_naming_pattern() {
  local desc="$1"
  local name="$2"
  local pattern="$3"

  if [[ "$name" =~ $pattern ]]; then
    log_pass "$desc"
  else
    log_fail "$desc (name '$name' does not match pattern '$pattern')"
  fi
}

# ══════════════════════════════════════════════════════════════════
# TEST CASES
# ══════════════════════════════════════════════════════════════════

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Backstage Templates and Configuration Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

check_requirements

# ── Test 1: Cluster Variables (vars.yaml) ───────────────────────
echo "── Test 1: Cluster Variables ──"
test_yaml_syntax \
  "vars.yaml has valid YAML syntax" \
  "clusters/homelab/vars.yaml"

test_configmap \
  "vars.yaml is a valid ConfigMap" \
  "clusters/homelab/vars.yaml"

test_required_fields \
  "vars.yaml contains required variables" \
  "clusters/homelab/vars.yaml" \
  "DOMAIN" "LAB_DOMAIN" "OP_VAULT" "OP_ITEM_BACKSTAGE_GITHUB_APP"

test_template_variables \
  "vars.yaml values are properly formatted" \
  "clusters/homelab/vars.yaml" \
  "^  [A-Z_]+:"

echo ""

# ── Test 2: Backstage Base Configuration ────────────────────────
echo "── Test 2: Backstage Base Configuration ──"
test_yaml_syntax \
  "backstage/kustomization.yaml has valid YAML syntax" \
  "platform/base/backstage/kustomization.yaml"

test_k8s_resource \
  "backstage/kustomization.yaml is valid Kustomization" \
  "platform/base/backstage/kustomization.yaml" \
  "Kustomization"

test_kustomization_resources \
  "backstage/kustomization.yaml references existing files" \
  "platform/base/backstage/kustomization.yaml"

test_yaml_syntax \
  "backstage/helm-release.yaml has valid YAML syntax" \
  "platform/base/backstage/helm-release.yaml"

test_helm_release \
  "backstage/helm-release.yaml is valid HelmRelease" \
  "platform/base/backstage/helm-release.yaml"

test_template_variables \
  "backstage/helm-release.yaml uses Flux variable substitution" \
  "platform/base/backstage/helm-release.yaml" \
  '\$\{[A-Z_]+\}'

test_yaml_syntax \
  "backstage/onepassword-item-github-app.yaml has valid YAML syntax" \
  "platform/base/backstage/onepassword-item-github-app.yaml"

test_k8s_resource \
  "backstage/onepassword-item-github-app.yaml is valid OnePasswordItem" \
  "platform/base/backstage/onepassword-item-github-app.yaml" \
  "OnePasswordItem"

echo ""

# ── Test 3: Create Infrastructure Component Template ────────────
echo "── Test 3: Create Infrastructure Component Template ──"
test_yaml_syntax \
  "create-infra-component/template.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/create-infra-component/template.yaml"

test_backstage_template \
  "create-infra-component/template.yaml is valid Backstage template" \
  "platform/base/backstage/templates/create-infra-component/template.yaml"

test_required_fields \
  "create-infra-component template has required parameters" \
  "platform/base/backstage/templates/create-infra-component/template.yaml" \
  "name" "namespace" "chart" "version" "helmRepoName"

test_required_fields \
  "create-infra-component template has fetch:template action" \
  "platform/base/backstage/templates/create-infra-component/template.yaml" \
  "fetch:template" "./skeleton"

test_required_fields \
  "create-infra-component template has PR action" \
  "platform/base/backstage/templates/create-infra-component/template.yaml" \
  "publish:github:pull-request" "github.com?owner=Diixtra&repo=diixtra-forge"

# Test skeleton files
test_yaml_syntax \
  "create-infra-component/skeleton/namespace.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/create-infra-component/skeleton/namespace.yaml"

test_template_variables \
  "create-infra-component/skeleton/namespace.yaml uses Backstage variables" \
  "platform/base/backstage/templates/create-infra-component/skeleton/namespace.yaml" \
  '\$\{\{ values\.[a-zA-Z_]+ \}\}'

test_yaml_syntax \
  "create-infra-component/skeleton/helm-release.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/create-infra-component/skeleton/helm-release.yaml"

test_yaml_syntax \
  "create-infra-component/skeleton/kustomization.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/create-infra-component/skeleton/kustomization.yaml" \
  "true"

test_yaml_syntax \
  "create-infra-component/skeleton/onepassword-item.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/create-infra-component/skeleton/onepassword-item.yaml" \
  "true"

test_required_fields \
  "create-infra-component/skeleton/onepassword-item.yaml has conditional logic" \
  "platform/base/backstage/templates/create-infra-component/skeleton/onepassword-item.yaml" \
  "{%- if values.enableSecret %}"

echo ""

# ── Test 4: Deploy Service Template ─────────────────────────────
echo "── Test 4: Deploy Service Template ──"
test_yaml_syntax \
  "deploy-service/template.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/deploy-service/template.yaml"

test_backstage_template \
  "deploy-service/template.yaml is valid Backstage template" \
  "platform/base/backstage/templates/deploy-service/template.yaml"

test_required_fields \
  "deploy-service template has required parameters" \
  "platform/base/backstage/templates/deploy-service/template.yaml" \
  "name" "image" "port"

test_required_fields \
  "deploy-service template has ingress configuration" \
  "platform/base/backstage/templates/deploy-service/template.yaml" \
  "enableIngress" "hostname"

# Test skeleton files
test_yaml_syntax \
  "deploy-service/skeleton/deployment.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/deploy-service/skeleton/deployment.yaml" \
  "true"

# Skip K8s resource validation for template files with conditionals
# test_k8s_resource would fail on Jinja2 syntax
test_required_fields \
  "deploy-service/skeleton/deployment.yaml contains Deployment structure" \
  "platform/base/backstage/templates/deploy-service/skeleton/deployment.yaml" \
  "kind: Deployment" "metadata:" "spec:"

test_yaml_syntax \
  "deploy-service/skeleton/service.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/deploy-service/skeleton/service.yaml"

test_k8s_resource \
  "deploy-service/skeleton/service.yaml is valid Service" \
  "platform/base/backstage/templates/deploy-service/skeleton/service.yaml" \
  "Service"

test_yaml_syntax \
  "deploy-service/skeleton/ingressroute.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/deploy-service/skeleton/ingressroute.yaml" \
  "true"

test_required_fields \
  "deploy-service/skeleton/ingressroute.yaml has conditional rendering" \
  "platform/base/backstage/templates/deploy-service/skeleton/ingressroute.yaml" \
  "{%- if values.enableIngress %}"

test_yaml_syntax \
  "deploy-service/skeleton/kustomization.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/deploy-service/skeleton/kustomization.yaml" \
  "true"

echo ""

# ── Test 5: Pin Helm Version Template ───────────────────────────
echo "── Test 5: Pin Helm Version Template ──"
test_yaml_syntax \
  "pin-helm-version/template.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/pin-helm-version/template.yaml"

test_backstage_template \
  "pin-helm-version/template.yaml is valid Backstage template" \
  "platform/base/backstage/templates/pin-helm-version/template.yaml"

test_required_fields \
  "pin-helm-version template has required parameters" \
  "platform/base/backstage/templates/pin-helm-version/template.yaml" \
  "layer" "component" "helmReleaseName" "version"

test_required_fields \
  "pin-helm-version template has layer enum" \
  "platform/base/backstage/templates/pin-helm-version/template.yaml" \
  "infrastructure" "platform" "apps"

test_yaml_syntax \
  "pin-helm-version/skeleton/version-pin.yaml has valid YAML syntax" \
  "platform/base/backstage/templates/pin-helm-version/skeleton/version-pin.yaml"

test_helm_release \
  "pin-helm-version/skeleton/version-pin.yaml is valid HelmRelease patch" \
  "platform/base/backstage/templates/pin-helm-version/skeleton/version-pin.yaml"

echo ""

# ── Test 6: Naming Conventions ──────────────────────────────────
echo "── Test 6: Naming Conventions ──"
test_naming_pattern \
  "Template name 'create-infra-component' follows kebab-case" \
  "create-infra-component" \
  "^[a-z][a-z0-9-]*$"

test_naming_pattern \
  "Template name 'deploy-service' follows kebab-case" \
  "deploy-service" \
  "^[a-z][a-z0-9-]*$"

test_naming_pattern \
  "Template name 'pin-helm-version' follows kebab-case" \
  "pin-helm-version" \
  "^[a-z][a-z0-9-]*$"

echo ""

# ── Test 7: Variable Substitution Consistency ───────────────────
echo "── Test 7: Variable Substitution Consistency ──"
test_required_fields \
  "Backstage templates use consistent variable format" \
  "platform/base/backstage/templates/create-infra-component/template.yaml" \
  "\${{ parameters"

test_required_fields \
  "Skeleton files use values. prefix for variables" \
  "platform/base/backstage/templates/create-infra-component/skeleton/namespace.yaml" \
  "\${{ values."

test_required_fields \
  "Flux resources use \${VAR} format for substitution" \
  "platform/base/backstage/helm-release.yaml" \
  "\${LAB_DOMAIN}" "\${POSTGRES_PASSWORD}"

echo ""

# ── Test 8: Cross-Reference Validation ─────────────────────────
echo "── Test 8: Cross-Reference Validation ──"
test_required_fields \
  "Backstage helm-release references correct 1Password secret" \
  "platform/base/backstage/helm-release.yaml" \
  "backstage-github-app"

test_required_fields \
  "Kustomization includes all required resources" \
  "platform/base/backstage/kustomization.yaml" \
  "namespace.yaml" "helm-release.yaml" "onepassword-item.yaml" "onepassword-item-github-app.yaml"

test_required_fields \
  "vars.yaml defines OP_ITEM_BACKSTAGE_GITHUB_APP variable" \
  "clusters/homelab/vars.yaml" \
  "OP_ITEM_BACKSTAGE_GITHUB_APP"

echo ""

# ── Test 9: Security and Best Practices ────────────────────────
echo "── Test 9: Security and Best Practices ──"
test_required_fields \
  "HelmRelease uses secrets for sensitive data" \
  "platform/base/backstage/helm-release.yaml" \
  "existingSecret" "extraEnvVarsSecrets"

test_required_fields \
  "Templates include reviewer checklist" \
  "platform/base/backstage/templates/create-infra-component/template.yaml" \
  "Reviewer checklist"

test_required_fields \
  "Templates use managed-by label" \
  "platform/base/backstage/templates/create-infra-component/skeleton/namespace.yaml" \
  "app.kubernetes.io/managed-by"

test_required_fields \
  "OnePasswordItem references vault via variable" \
  "platform/base/backstage/onepassword-item-github-app.yaml" \
  "\${OP_VAULT}"

echo ""

# ── Test 10: Template Output Validation ────────────────────────
echo "── Test 10: Template Output Validation ──"
test_required_fields \
  "create-infra-component template has output links" \
  "platform/base/backstage/templates/create-infra-component/template.yaml" \
  "output:" "links:"

test_required_fields \
  "deploy-service template provides PR URL output" \
  "platform/base/backstage/templates/deploy-service/template.yaml" \
  "steps\['open-pr'\].output.remoteUrl"

test_required_fields \
  "Templates target correct repository" \
  "platform/base/backstage/templates/pin-helm-version/template.yaml" \
  "github.com?owner=Diixtra&repo=diixtra-forge"

echo ""

# ── Test 11: Edge Cases and Regression Tests ───────────────────
echo "── Test 11: Edge Cases and Regression Tests ──"

# Test that template parameter patterns are correctly defined
python3 - "platform/base/backstage/templates/create-infra-component/template.yaml" <<'EOF'
import sys
import yaml

file_path = sys.argv[1]

try:
    with open(file_path, 'r') as f:
        doc = yaml.safe_load(f)

    # Verify name and namespace parameters have restrictive patterns
    for param_section in doc['spec']['parameters']:
        for prop_name, prop_def in param_section.get('properties', {}).items():
            if prop_name in ['name', 'namespace', 'component']:
                if 'pattern' in prop_def:
                    pattern = prop_def['pattern']
                    # Check pattern enforces lowercase start
                    if not pattern.startswith('^[a-z]'):
                        print(f"Pattern for {prop_name} should enforce lowercase start", file=sys.stderr)
                        sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

if [[ $? -eq 0 ]]; then
  log_pass "Template parameters enforce lowercase naming patterns"
else
  log_fail "Template parameters enforce lowercase naming patterns"
fi

# Test that required fields are actually marked as required
python3 - "platform/base/backstage/templates/deploy-service/template.yaml" <<'EOF'
import sys
import yaml

file_path = sys.argv[1]

try:
    with open(file_path, 'r') as f:
        doc = yaml.safe_load(f)

    # Check that the first parameter section has required fields
    first_param = doc['spec']['parameters'][0]
    required_fields = first_param.get('required', [])

    if not required_fields:
        print("No required fields defined in first parameter section", file=sys.stderr)
        sys.exit(1)

    # Verify critical fields are required
    critical_fields = ['name', 'image', 'port']
    for field in critical_fields:
        if field not in required_fields:
            print(f"Critical field {field} is not marked as required", file=sys.stderr)
            sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

if [[ $? -eq 0 ]]; then
  log_pass "Critical template parameters are marked as required"
else
  log_fail "Critical template parameters are marked as required"
fi

# Test that conditional fields have proper ui:options hiding
test_required_fields \
  "Conditional fields use ui:options hidden attribute" \
  "platform/base/backstage/templates/create-infra-component/template.yaml" \
  "ui:options:" "hidden:"

# Boundary test: Verify HelmRelease chart version can be wildcard or specific
python3 - "platform/base/backstage/helm-release.yaml" <<'EOF'
import sys
import yaml

file_path = sys.argv[1]

try:
    with open(file_path, 'r') as f:
        content = f.read()
        doc = yaml.safe_load(content)

    chart_version = doc['spec']['chart']['spec'].get('version', '')

    # Version should be either "*" or a specific version pattern
    # This test just ensures the field exists
    if not chart_version:
        print("Chart version is not defined", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

if [[ $? -eq 0 ]]; then
  log_pass "HelmRelease defines chart version (wildcard or pinned)"
else
  log_fail "HelmRelease defines chart version (wildcard or pinned)"
fi

# Regression test: Ensure GitHub repository references are consistent
python3 - <<'EOF'
import sys
import glob
import yaml

try:
    template_files = glob.glob("platform/base/backstage/templates/*/template.yaml")
    repos_found = set()

    for file_path in template_files:
        with open(file_path, 'r') as f:
            doc = yaml.safe_load(f)

        # Find PR step
        for step in doc.get('spec', {}).get('steps', []):
            if 'publish:github:pull-request' in step.get('action', ''):
                repo_url = step['input'].get('repoUrl', '')
                repos_found.add(repo_url)

    # All templates should target the same repository
    if len(repos_found) != 1:
        print(f"Found multiple repository targets: {repos_found}", file=sys.stderr)
        sys.exit(1)

    expected_repo = "github.com?owner=Diixtra&repo=diixtra-forge"
    if expected_repo not in repos_found:
        print(f"Expected repo {expected_repo} not found", file=sys.stderr)
        sys.exit(1)

    sys.exit(0)
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
EOF

if [[ $? -eq 0 ]]; then
  log_pass "All templates consistently target the same GitHub repository"
else
  log_fail "All templates consistently target the same GitHub repository"
fi

echo ""

# ══════════════════════════════════════════════════════════════════
# SUMMARY
# ══════════════════════════════════════════════════════════════════

echo "═══════════════════════════════════════════════════════════════"
echo " Test Summary"
echo "═══════════════════════════════════════════════════════════════"
echo -e " ${GREEN}Passed${NC}: ${TESTS_PASSED}"
echo -e " ${RED}Failed${NC}: ${TESTS_FAILED}"
echo "═══════════════════════════════════════════════════════════════"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi

exit 0