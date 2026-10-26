#!/usr/bin/env bash
# CPSY 300 Project Phase 1 — automates the Azure side of Parts D and E.
#
#   D1  resource group + Standard container registry
#   D2  first image (recipes:v1) built locally and pushed
#   D3  Container Apps environment
#   D4  container app (managed-identity pull, DASHBOARD_TITLE, ingress :3000, 0.25 CPU / 0.5Gi, min replicas 0)
#   E1  pipeline identity gh-deploy
#   E3  two federated credentials (name form + id form), looked up from the GitHub API
#   E4  Contributor on the project resource group only, then prints the three GitHub secrets
#   E5  (optional, --set-gh-secrets) writes those secrets with the gh CLI
#
# Safe to re-run: every step checks whether its resource already exists first.
# It never deletes anything (Phase 2 and 3 build on all of it).
#
# Not automated (the brief wants them done by hand / they are GitHub-side):
#   S2/S4 repo + branch protection, Part C Dockerfile, E2 whoami workflow,
#   E6 deploy.yml (the env: block is printed at the end), D5 revision demo.
#
# Requirements: az (logged in to the HOST's subscription), curl.
# Docker is needed only when recipes:v1 is not yet in the registry
# (so run on the host's laptop the first time — Cloud Shell has no Docker daemon).
# Uses the containerapp commands built into az, so no az extension is installed
# (on NixOS, `az extension add` fails and nixpkgs' containerapp extension does not build).
#
# NixOS on WSL: Docker Desktop's own docker binary segfaults there, so take the
# client from nixpkgs (needs wsl.docker-desktop.enable = true for /var/run/docker.sock):
#   nix shell nixpkgs#docker-client nixpkgs#docker-buildx -c ./setup-azure.sh ...
#
# Usage:
#   ./setup-azure.sh --team kale --github <owner>/cpsy300-kale \
#       [--location canadacentral] [--title "Kale's recipe insights"] \
#       [--repo-dir ~/cpsy300/cpsy300-kale] [--set-gh-secrets]

set -euo pipefail

# Git Bash on Windows rewrites "/subscriptions/..." into a Windows path; stop that.
export MSYS_NO_PATHCONV=1

TEAM="eric"
GITHUB_REPO="LeaderbotX400/sait-cpsy-300-project"
LOCATION="canadacentral"
TITLE=""
REPO_DIR="."
SET_GH_SECRETS=true

usage() { sed -n '2,/^$/p' "$0"| sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
step()  { echo; echo "==> $*"; }

# az on Windows prints CRLF; strip it so values compare and interpolate cleanly.
azq() { az "$@" | tr -d '\r'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team)           TEAM="${2:-}"; shift 2 ;;
    --github)         GITHUB_REPO="${2:-}"; shift 2 ;;
    --location)       LOCATION="${2:-}"; shift 2 ;;
    --title)          TITLE="${2:-}"; shift 2 ;;
    --repo-dir)       REPO_DIR="${2:-}"; shift 2 ;;
    --set-gh-secrets) SET_GH_SECRETS=true; shift ;;
    -h|--help)        usage 0 ;;
    *)                echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# ---------------------------------------------------------------- validation
[[ "$TEAM" =~ ^[a-z0-9]{3,10}$ ]] || die "--team must be 3-10 lowercase letters/digits (S1)."
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--github must be <owner>/<repo>."
[[ "${GITHUB_REPO#*/}" == "cpsy300-$TEAM" ]] \
  || echo "WARNING: repo name '${GITHUB_REPO#*/}' is not cpsy300-$TEAM as the brief asks."
[[ -n "$TITLE" ]] || TITLE="Recipe insights — $TEAM"

for cmd in az curl; do
  command -v "$cmd" >/dev/null || die "'$cmd' is not installed."
done
$SET_GH_SECRETS && { command -v gh >/dev/null || die "--set-gh-secrets needs the gh CLI."; }

RG="rg-cpsy300-project-$TEAM"
ENV_NAME="cae-cpsy300-$TEAM"
APP="ca-recipes-$TEAM"
IDENTITY="gh-deploy"
IMAGE_REPO="recipes"
IMAGE_TAG="v1"

step "Checking Azure sign-in"
az account show >/dev/null 2>&1 || die "Not signed in. Run: az login"
# A cached account can still have an expired token; fail here, not halfway through.
az account get-access-token -o none 2>/dev/null || die "Azure sign-in has expired. Run: az login"
SUB=$(azq account show --query id -o tsv)
TENANT=$(azq account show --query tenantId -o tsv)
echo "Subscription: $(azq account show --query name -o tsv) ($SUB)"
read -r -p "Is this the HOST's Azure for Students subscription? [y/N] " ok
[[ "$ok" =~ ^[Yy]$ ]] || die "Switch with: az account set --subscription <id>"

step "Registering resource providers (first time can take a few minutes)"
for ns in Microsoft.ContainerRegistry Microsoft.App Microsoft.OperationalInsights Microsoft.ManagedIdentity; do
  state=$(azq provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)
  if [[ "$state" != "Registered" ]]; then
    echo "  registering $ns ..."
    az provider register -n "$ns" --wait >/dev/null
  fi
done

# ---------------------------------------------------------------- D1
step "D1 · Resource group $RG"
if [[ "$(azq group exists -n "$RG")" == "true" ]]; then
  LOCATION=$(azq group show -n "$RG" --query location -o tsv)
  echo "  exists (region $LOCATION)"
else
  az group create -n "$RG" -l "$LOCATION" -o none
  echo "  created in $LOCATION"
fi

step "D1 · Container registry"
ACR=$(azq acr list -g "$RG" --query "[?starts_with(name, 'acrcpsy300$TEAM')].name | [0]" -o tsv)
if [[ -n "$ACR" ]]; then
  echo "  exists: $ACR"
else
  # One Standard registry per student subscription is free; a second one is billed daily.
  OTHER=$(azq acr list --query "[?sku.name=='Standard'].name" -o tsv)
  if [[ -n "$OTHER" ]]; then
    echo "Existing Standard registries in this subscription:"; echo "$OTHER" | sed 's/^/  /'
    die "Delete the old (Lab 2/class) registry first, or one of them is charged every day."
  fi
  for _ in 1 2 3 4 5; do
    candidate="acrcpsy300${TEAM}$(printf '%04d' $((RANDOM % 10000)))"
    if [[ "$(azq acr check-name -n "$candidate" --query nameAvailable -o tsv)" == "true" ]]; then
      ACR="$candidate"; break
    fi
  done
  [[ -n "$ACR" ]] || die "Could not find a free registry name; re-run the script."
  # Portal defaults match the brief: DNL scope Unsecure, RBAC Registry Permissions.
  az acr create -n "$ACR" -g "$RG" -l "$LOCATION" --sku Standard -o none
  echo "  created: $ACR"
fi
LOGIN_SERVER=$(azq acr show -n "$ACR" --query loginServer -o tsv)

# ---------------------------------------------------------------- D2
step "D2 · First image $LOGIN_SERVER/$IMAGE_REPO:$IMAGE_TAG"
if azq acr repository show-tags -n "$ACR" --repository "$IMAGE_REPO" -o tsv 2>/dev/null | grep -qx "$IMAGE_TAG"; then
  echo "  already in the registry"
else
  command -v docker >/dev/null && docker info >/dev/null 2>&1 \
    || die "recipes:v1 is not in $ACR yet and Docker is not running here. Run this script on the host's laptop with Docker Desktop started (Cloud Shell has no Docker)."
  [[ -f "$REPO_DIR/Dockerfile" ]] \
    || die "No Dockerfile in '$REPO_DIR'. Pass --repo-dir pointing at the up-to-date main checkout (Part C must be merged)."
  [[ -f "$REPO_DIR/data/All_Diets.csv" ]] || die "'$REPO_DIR/data/All_Diets.csv' is missing (S3 step 5)."
  # az acr login uses your Azure sign-in, so the registry admin user is not needed.
  az acr login -n "$ACR"
  docker build --platform linux/amd64 -t "$IMAGE_REPO:local" "$REPO_DIR"
  docker tag "$IMAGE_REPO:local" "$LOGIN_SERVER/$IMAGE_REPO:$IMAGE_TAG"
  docker push "$LOGIN_SERVER/$IMAGE_REPO:$IMAGE_TAG"
fi

# ---------------------------------------------------------------- D3
step "D3 · Container Apps environment $ENV_NAME"
if az containerapp env show -n "$ENV_NAME" -g "$RG" -o none 2>/dev/null; then
  echo "  exists"
else
  echo "  creating (a few minutes) ..."
  az containerapp env create -n "$ENV_NAME" -g "$RG" -l "$LOCATION" -o none
fi
ENV_ID=$(azq containerapp env show -n "$ENV_NAME" -g "$RG" --query id -o tsv)

# ---------------------------------------------------------------- D4
step "D4 · Container app $APP"
if az containerapp show -n "$APP" -g "$RG" -o none 2>/dev/null; then
  # Leave it alone: after Part E the pipeline owns the image tag.
  echo "  exists — not touched"
else
  echo "  creating (3-5 minutes) ..."
  # --registry-identity system gives the app's own identity AcrPull on the registry.
  if ! az containerapp create \
        -n "$APP" -g "$RG" \
        --environment "$ENV_ID" \
        --container-name "$IMAGE_REPO" \
        --image "$LOGIN_SERVER/$IMAGE_REPO:$IMAGE_TAG" \
        --registry-server "$LOGIN_SERVER" \
        --registry-identity system \
        --cpu 0.25 --memory 0.5Gi \
        --min-replicas 0 \
        --ingress external --target-port 3000 \
        --env-vars "DASHBOARD_TITLE=$TITLE" \
        -o none; then
    cat >&2 <<EOF
Container app creation failed. The usual cause is the AcrPull permission not
having arrived yet (brief, red box in Part D). Delete the app, wait five
minutes and re-run this script:
  az containerapp delete -n $APP -g $RG --yes
EOF
    exit 1
  fi
fi
APP_URL="https://$(azq containerapp show -n "$APP" -g "$RG" --query properties.configuration.ingress.fqdn -o tsv)"
echo "  Application Url: $APP_URL"

# ---------------------------------------------------------------- E1
step "E1 · Pipeline identity $IDENTITY"
az identity create -n "$IDENTITY" -g "$RG" -l "$LOCATION" -o none
CLIENT_ID=$(azq identity show -n "$IDENTITY" -g "$RG" --query clientId -o tsv)
PRINCIPAL=$(azq identity show -n "$IDENTITY" -g "$RG" --query principalId -o tsv)

# ---------------------------------------------------------------- E3
step "E3 · Federated credentials for $GITHUB_REPO (main only)"
# Same two subjects the whoami workflow (E2) prints, read from GitHub's public API.
GH_JSON=$(curl -fsSL "https://api.github.com/repos/$GITHUB_REPO") \
  || die "GitHub API could not find $GITHUB_REPO (it must exist and be public)."
# No jq needed: the API pretty-prints, top-level keys indented 2 spaces and the
# owner object's keys 4 (owner is the first nested object, so its keys match first).
jfield() { sed -nE "s/^$1\"$2\": \"?([^\",]*)\"?,?\r?\$/\1/p" <<<"$GH_JSON" | head -n1; }
GH_FULL=$(jfield "  " full_name)
GH_OWNER=$(jfield "    " login)
GH_OWNER_ID=$(jfield "    " id)
GH_REPO_ID=$(jfield "  " id)
[[ -n "$GH_FULL" && -n "$GH_OWNER" && "$GH_OWNER_ID$GH_REPO_ID" =~ ^[0-9]+$ ]] \
  || die "Could not read the repository IDs from the GitHub API response."
SUB_NAME="repo:${GH_FULL}:ref:refs/heads/main"
SUB_IDS="repo:${GH_OWNER}@${GH_OWNER_ID}/${GH_FULL#*/}@${GH_REPO_ID}:ref:refs/heads/main"
echo "  NAME: $SUB_NAME"
echo "  IDS:  $SUB_IDS"

add_fic() {
  local name=$1 subject=$2 current
  current=$(azq identity federated-credential show --name "$name" --identity-name "$IDENTITY" -g "$RG" \
              --query subject -o tsv 2>/dev/null || true)
  if [[ "$current" == "$subject" ]]; then
    echo "  $name exists"
    return
  fi
  [[ -n "$current" ]] && die "$name exists with a different subject ($current). Delete it in the portal and re-run."
  az identity federated-credential create \
    --name "$name" --identity-name "$IDENTITY" -g "$RG" \
    --issuer https://token.actions.githubusercontent.com \
    --subject "$subject" --audiences api://AzureADTokenExchange -o none
  echo "  $name created"
}
add_fic github-name "$SUB_NAME"
add_fic github-ids  "$SUB_IDS"

# ---------------------------------------------------------------- E4
step "E4 · Contributor on $RG only"
SCOPE="/subscriptions/$SUB/resourceGroups/$RG"
if [[ -n "$(azq role assignment list --assignee "$PRINCIPAL" --role Contributor --scope "$SCOPE" --query '[0].id' -o tsv)" ]]; then
  echo "  exists"
else
  # A brand-new identity can take a few seconds to be visible to RBAC.
  for attempt in 1 2 3 4 5 6; do
    if az role assignment create \
         --assignee-object-id "$PRINCIPAL" \
         --assignee-principal-type ServicePrincipal \
         --role Contributor --scope "$SCOPE" -o none 2>/dev/null; then
      echo "  created"; break
    fi
    [[ $attempt -eq 6 ]] && die "Role assignment failed. Re-run the script in a minute."
    sleep 10
  done
fi

# ---------------------------------------------------------------- E5
if $SET_GH_SECRETS; then
  step "E5 · Writing GitHub secrets with gh"
  gh secret set AZURE_CLIENT_ID       -R "$GITHUB_REPO" -b "$CLIENT_ID"
  gh secret set AZURE_TENANT_ID       -R "$GITHUB_REPO" -b "$TENANT"
  gh secret set AZURE_SUBSCRIPTION_ID -R "$GITHUB_REPO" -b "$SUB"
fi

# ---------------------------------------------------------------- summary
cat <<EOF

================================================================
Done.

Live app:   $APP_URL
Registry:   $ACR  ($LOGIN_SERVER)

GitHub secrets (E5) — repository → Settings → Secrets and variables → Actions.
Send privately; never commit or screenshot these:
  AZURE_CLIENT_ID=$CLIENT_ID
  AZURE_TENANT_ID=$TENANT
  AZURE_SUBSCRIPTION_ID=$SUB
$($SET_GH_SECRETS && echo "  (already written to $GITHUB_REPO with gh)")

The env: block for .github/workflows/deploy.yml (E6):
  env:
    ACR_NAME: $ACR
    RESOURCE_GROUP: $RG
    CONTAINERAPP: $APP

Still by hand: D5 (new revision with a different DASHBOARD_TITLE, screenshots),
E2 whoami workflow if your instructor wants to see it, E6/E7 pipeline PRs.
================================================================
EOF
