#!/usr/bin/env bash
# CPSY 300 Project Phase 1 — automates the Azure side of Parts D and E.
#
#   up    (default) create everything below; safe to re-run
#   down  delete the whole resource group rg-cpsy300-project-<team>
#         (asks you to type the group's name first)
#
# up does:
#   D1  resource group + Standard container registry
#   D2  first image (recipes:v1) built locally and pushed
#   D3  Container Apps environment
#   D4  container app (managed-identity pull, DASHBOARD_TITLE, ingress :3000, 0.25 CPU / 0.5Gi, min replicas 0)
#   E1  pipeline identity gh-deploy
#   E3  two federated credentials (name form + id form), looked up from the GitHub API
#   E4  Contributor on the project resource group only, then prints the three GitHub secrets
#   E5  (optional, --set-gh-secrets) writes those secrets with the gh CLI
#
# Phase 2 (serverless back end; same resource group, nothing from Phase 1 is touched):
#   P2-1  Cosmos DB account (free tier if the subscription has none, else Serverless),
#         database recipesdb + containers recipes /diet, insights /id, reviews /recipeId
#   P2-2  uploads storage account + container "uploads"
#   P2-3  Service Bus namespace (Basic) + queue "reviews"
#   P2-4  Function App (Flex Consumption, Node 24, App Insights, system identity)
#   P2-5  four roles for the Function App's identity (Cosmos, Blob Owner, Queue Contributor, SB Receiver)
#   P2-6  the six app settings (no keys, only __credential=managedidentity)
#   P2-7  container app: identity, Service Bus Sender role, API_BASE_URL + SERVICEBUS_NAMESPACE
#   P2-8  (--deploy-api)  run the "Deploy the API" workflow on main and wait for it
#   P2-9  Event Grid subscription uploads-to-processcsv (needs the API deployed first)
#   P2-10 (--upload-csv)  upload All_Diets.csv to the uploads container
# Fast rebuild:  down, then  up --yes --set-gh-secrets --deploy-api --upload-csv
# Still by hand: the saved KQL query (brief step 13) and the screenshots.
#
# up is safe to re-run: every step checks whether its resource already exists first.
# down removes EVERYTHING up made. The brief says to keep it all after the Phase 1
# hand-in (Phases 2 and 3 build on it). After a down, up starts over with a new
# registry name and a new pipeline identity; pass --set-gh-secrets to update the
# GitHub secrets. deploy.yml looks up the registry name itself.
#
# In the repo, not here: Dockerfile (Part C), .github/workflows/ci.yml (PR checks),
# .github/workflows/deploy.yml (E6; finds the registry by name prefix).
# Not automated: S2/S4 repo + branch protection, E2 whoami workflow, D5 revision demo.
#
# Requirements: az (logged in to the HOST's subscription), curl.
# Docker is needed only when recipes:v1 is not yet in the registry
# (so run on the host's laptop the first time — Cloud Shell has no Docker daemon).
# Uses the containerapp commands built into az, so no az extension is installed
# (on NixOS, `az extension add` fails and nixpkgs' containerapp extension does not build).
#
# NixOS on WSL: Docker Desktop's own docker binary segfaults there, so take the
# client from nixpkgs (needs wsl.docker-desktop.enable = true for /var/run/docker.sock):
#   devenv shell -- ./setup-azure.sh ...   (devenv.nix provides az, gh, curl, docker)
#
# Usage:
#   ./setup-azure.sh [up|down] --team kale --github <owner>/cpsy300-kale \
#       [--location canadacentral] [--cosmos-location westus3] [--title "Kale's recipe insights"] \
#       [--repo-dir ~/cpsy300/cpsy300-kale] [--set-gh-secrets]
#       [--digits 7315] [--yes] [--deploy-api] [--upload-csv]

set -euo pipefail

# Git Bash on Windows rewrites "/subscriptions/..." into a Windows path; stop that.
export MSYS_NO_PATHCONV=1

TEAM="eric"
GITHUB_REPO="LeaderbotX400/sait-cpsy-300-project"
LOCATION="canadacentral"
COSMOS_LOCATION=""
TITLE=""
REPO_DIR="."
SET_GH_SECRETS=false
DIGITS="7315"
ASSUME_YES=false
DEPLOY_API=false
UPLOAD_CSV=false
ACTION=up

usage() { sed -n '2,/^$/p' "$0"| sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die()   { echo "ERROR: $*" >&2; exit 1; }
step()  { echo; echo "==> $*"; }

# az on Windows prints CRLF; strip it so values compare and interpolate cleanly.
azq() { az "$@" | tr -d '\r'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    up|down)          ACTION="$1"; shift ;;
    --team)           TEAM="${2:-}"; shift 2 ;;
    --github)         GITHUB_REPO="${2:-}"; shift 2 ;;
    --location)       LOCATION="${2:-}"; shift 2 ;;
    --cosmos-location) COSMOS_LOCATION="${2:-}"; shift 2 ;;
    --title)          TITLE="${2:-}"; shift 2 ;;
    --repo-dir)       REPO_DIR="${2:-}"; shift 2 ;;
    --set-gh-secrets) SET_GH_SECRETS=true; shift ;;
    --digits)         DIGITS="${2:-}"; shift 2 ;;
    --yes|-y)         ASSUME_YES=true; shift ;;
    --deploy-api)     DEPLOY_API=true; shift ;;
    --upload-csv)     UPLOAD_CSV=true; shift ;;
    -h|--help)        usage 0 ;;
    *)                echo "Unknown option: $1" >&2; usage 1 ;;
  esac
done

# ---------------------------------------------------------------- validation
[[ "$TEAM" =~ ^[a-z0-9]{3,10}$ ]] || die "--team must be 3-10 lowercase letters/digits (S1)."
[[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--github must be <owner>/<repo>."
[[ "${GITHUB_REPO#*/}" == "cpsy300-$TEAM" ]] \
  || echo "WARNING: repo name '${GITHUB_REPO#*/}' is not cpsy300-$TEAM as the brief asks."
[[ "$DIGITS" =~ ^[0-9]{4}$ ]] || die "--digits must be exactly 4 digits."
[[ -n "$TITLE" ]] || TITLE="Recipe insights — $TEAM"

command -v az >/dev/null || die "'az' is not installed."
if [[ "$ACTION" == up ]]; then
  command -v curl >/dev/null || die "'curl' is not installed."
  if $SET_GH_SECRETS || $DEPLOY_API; then command -v gh >/dev/null || die "--set-gh-secrets / --deploy-api need the gh CLI."; fi
fi

RG="rg-cpsy300-project-$TEAM"
ENV_NAME="cae-cpsy300-$TEAM"
APP="ca-recipes-$TEAM"
IDENTITY="gh-deploy"
IMAGE_REPO="recipes"
IMAGE_TAG="v1"

# Phase 2 names (brief: "Names and who does what")
COSMOS="cosmos-recipes-$TEAM-$DIGITS"
UPLOADS="stuploads$TEAM$DIGITS"
SB="sb-recipes-$TEAM-$DIGITS"
FN="fn-recipes-$TEAM-$DIGITS"
FN_STORAGE="stfnrecipes$TEAM$DIGITS"
[[ ${#UPLOADS} -le 24 && ${#FN_STORAGE} -le 24 ]] || die "--team is too long for the storage account names (24 characters max)."

step "Checking Azure sign-in"
az account show >/dev/null 2>&1 || die "Not signed in. Run: az login"
# A cached account can still have an expired token; fail here, not halfway through.
az account get-access-token -o none 2>/dev/null || die "Azure sign-in has expired. Run: az login"
SUB=$(azq account show --query id -o tsv)
TENANT=$(azq account show --query tenantId -o tsv)
echo "Subscription: $(azq account show --query name -o tsv) ($SUB)"
if $ASSUME_YES; then ok=y; else read -r -p "Is this the HOST's Azure for Students subscription? [y/N] " ok; fi
[[ "$ok" =~ ^[Yy]$ ]] || die "Switch with: az account set --subscription <id>"

# ---------------------------------------------------------------- down
if [[ "$ACTION" == down ]]; then
  step "Deleting resource group $RG"
  if [[ "$(azq group exists -n "$RG")" != "true" ]]; then
    echo "  $RG does not exist — nothing to delete."
    exit 0
  fi
  az resource list -g "$RG" -o table
  cat <<EOF

WARNING: this deletes everything above, for good. The brief says to keep it
all after the Phase 1 hand-in (Phases 2 and 3 build on it).
EOF
  read -r -p "Type the resource group name to confirm: " confirm
  [[ "$confirm" == "$RG" ]] || die "Name did not match; nothing deleted."
  echo "  deleting (several minutes) ..."
  az group delete -n "$RG" --yes
  echo "  deleted. A Cosmos DB free tier is released only now (one per subscription)."
  if [[ "$(azq group exists -n LogAnalyticsDefaultResources)" == "true" ]]; then
    echo "  LogAnalyticsDefaultResources (the saved-query pack from brief step 13) is left over:"
    az resource list -g LogAnalyticsDefaultResources -o table || true
    read -r -p "Delete LogAnalyticsDefaultResources too? [y/N] " dl
    [[ "$dl" =~ ^[Yy]$ ]] && az group delete -n LogAnalyticsDefaultResources --yes
  fi
  echo "  Run '$0 up --yes --set-gh-secrets --deploy-api --upload-csv' to create it all again."
  exit 0
fi

step "Registering resource providers (first time can take a few minutes)"
for ns in Microsoft.ContainerRegistry Microsoft.App Microsoft.OperationalInsights Microsoft.ManagedIdentity \
         Microsoft.DocumentDB Microsoft.Storage Microsoft.ServiceBus Microsoft.Web Microsoft.EventGrid Microsoft.Insights; do
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
    echo "Existing Standard registries in this subscription:"; while read -r r; do echo "  $r"; done <<<"$OTHER"
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
  { command -v docker >/dev/null && docker info >/dev/null 2>&1; } \
    || die "recipes:v1 is not in $ACR yet and Docker is not running here. Run this script on the host's laptop with Docker Desktop started (Cloud Shell has no Docker)."
  [[ -f "$REPO_DIR/Dockerfile" ]] \
    || die "No Dockerfile in '$REPO_DIR'. Pass --repo-dir pointing at the up-to-date main checkout (Part C must be merged)."
  # az acr login uses your Azure sign-in, so the registry admin user is not needed.
  az acr login -n "$ACR"
  docker build --platform linux/amd64 -t "$IMAGE_REPO:local" "$REPO_DIR"
  docker tag "$IMAGE_REPO:local" "$LOGIN_SERVER/$IMAGE_REPO:$IMAGE_TAG"
  docker push "$LOGIN_SERVER/$IMAGE_REPO:$IMAGE_TAG"
fi

# ---------------------------------------------------------------- D3
step "D3 · Container Apps environment $ENV_NAME"
# `az containerapp env create` (az 2.86) now gets an Express environment, which
# rejects the managed-identity registry pull D4 needs, and has no flag to say
# otherwise. So create it from an ARM template with environmentMode set to
# WorkloadProfiles (the brief's Consumption environment). listKeys() reads the
# Log Analytics key inside Azure, so it never reaches this script.
ENV_API=2026-07-01
if az containerapp env show -n "$ENV_NAME" -g "$RG" -o none 2>/dev/null; then
  echo "  exists"
else
  echo "  creating (a few minutes) ..."
  TEMPLATE=$(mktemp --suffix=.json)
  trap 'rm -f "$TEMPLATE"' EXIT
  cat >"$TEMPLATE" <<EOF
{
  "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "resources": [
    {
      "type": "Microsoft.OperationalInsights/workspaces",
      "apiVersion": "2023-09-01",
      "name": "law-cpsy300-$TEAM",
      "location": "$LOCATION",
      "properties": { "sku": { "name": "PerGB2018" }, "retentionInDays": 30 }
    },
    {
      "type": "Microsoft.App/managedEnvironments",
      "apiVersion": "$ENV_API",
      "name": "$ENV_NAME",
      "location": "$LOCATION",
      "dependsOn": [ "[resourceId('Microsoft.OperationalInsights/workspaces', 'law-cpsy300-$TEAM')]" ],
      "properties": {
        "environmentMode": "WorkloadProfiles",
        "workloadProfiles": [ { "name": "Consumption", "workloadProfileType": "Consumption" } ],
        "appLogsConfiguration": {
          "destination": "log-analytics",
          "logAnalyticsConfiguration": {
            "customerId": "[reference(resourceId('Microsoft.OperationalInsights/workspaces', 'law-cpsy300-$TEAM'), '2023-09-01').customerId]",
            "sharedKey": "[listKeys(resourceId('Microsoft.OperationalInsights/workspaces', 'law-cpsy300-$TEAM'), '2023-09-01').primarySharedKey]"
          }
        }
      }
    }
  ]
}
EOF
  az deployment group create -g "$RG" -n "cae-cpsy300-$TEAM" --template-file "$TEMPLATE" -o none
fi
ENV_ID=$(azq containerapp env show -n "$ENV_NAME" -g "$RG" --query id -o tsv)
ENV_MODE=$(azq rest --method get --url "https://management.azure.com$ENV_ID?api-version=$ENV_API" \
             --query properties.environmentMode -o tsv)
echo "  mode: $ENV_MODE"
if [[ "$ENV_MODE" == "Express" ]]; then
  cat >&2 <<EOF
ERROR: $ENV_NAME is an Express environment. Express rejects the managed-identity
registry pull (ExpressRegistrySystemIdentityNotSupported). Delete the app and the
environment, then re-run this script; it recreates the environment in the right mode:
  az containerapp delete -n $APP -g $RG --yes
  az containerapp env delete -n $ENV_NAME -g $RG --yes
EOF
  exit 1
fi

# ---------------------------------------------------------------- D4
step "D4 · Container app $APP"
if az containerapp show -n "$APP" -g "$RG" -o none 2>/dev/null; then
  # A create that failed halfway leaves the app on Azure's placeholder image.
  if azq containerapp show -n "$APP" -g "$RG" --query "properties.template.containers[0].image" -o tsv \
       | grep -q '^mcr.microsoft.com/k8se/quickstart'; then
    die "$APP is half-created (placeholder image). Delete it and re-run: az containerapp delete -n $APP -g $RG --yes"
  fi
  # Otherwise leave it alone: after Part E the pipeline owns the image tag.
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


# ================================================================ Phase 2
# Roles are looked up first so a re-run changes nothing. A new identity can take a
# while to be visible to RBAC, hence the retries.
ensure_role() {  # principal-id scope role
  local who=$1 scope=$2 role=$3 attempt
  if [[ -n "$(azq role assignment list --assignee "$who" --role "$role" --scope "$scope" --query '[0].id' -o tsv 2>/dev/null)" ]]; then
    echo "  $role exists"; return
  fi
  for attempt in 1 2 3 4 5 6; do
    if az role assignment create --assignee-object-id "$who" --assignee-principal-type ServicePrincipal \
         --role "$role" --scope "$scope" -o none 2>/dev/null; then
      echo "  $role created"; return
    fi
    [[ $attempt -eq 6 ]] && die "Could not assign $role. Re-run the script in a minute."
    sleep 10
  done
}

# ---------------------------------------------------------------- P2-1
step "P2-1 · Cosmos DB $COSMOS"
SERVERLESS=false
# A refused create leaves a "Failed" account that holds the name in every region: remove it first.
if [[ "$(azq cosmosdb show -n "$COSMOS" -g "$RG" --query provisioningState -o tsv 2>/dev/null)" == "Failed" ]]; then
  echo "  removing the failed account left by an earlier refused create ..."
  az cosmosdb delete -n "$COSMOS" -g "$RG" --yes -o none
fi
if az cosmosdb show -n "$COSMOS" -g "$RG" -o none 2>/dev/null; then
  echo "  exists"
  [[ "$(azq cosmosdb show -n "$COSMOS" -g "$RG" --query "length(capabilities[?name=='EnableServerless'])" -o tsv)" != "0" ]] && SERVERLESS=true
else
  if [[ "$(azq cosmosdb list --query "length([?enableFreeTier])" -o tsv)" == "0" ]]; then
    MODE_FLAGS=(--enable-free-tier true); echo "  free tier is available: using it (provisioned, 1000 RU/s shared)"
  else
    MODE_FLAGS=(--capabilities EnableServerless); SERVERLESS=true
    echo "  another account in this subscription already has the free tier: using Serverless (say so in the report)"
  fi
  echo "  creating (5-10 minutes) ..."
  # Cosmos DB can be refused for capacity in a region; --cosmos-location puts it elsewhere.
  CL="${COSMOS_LOCATION:-$LOCATION}"
  if ! az cosmosdb create -n "$COSMOS" -g "$RG" --kind GlobalDocumentDB "${MODE_FLAGS[@]}" \
         --locations regionName="$CL" failoverPriority=0 isZoneRedundant=False -o none; then
    echo "  $CL refused; trying canadaeast (any region works; or pass --cosmos-location)"
    if az cosmosdb show -n "$COSMOS" -g "$RG" -o none 2>/dev/null; then
      az cosmosdb delete -n "$COSMOS" -g "$RG" --yes -o none
    fi
    az cosmosdb create -n "$COSMOS" -g "$RG" --kind GlobalDocumentDB "${MODE_FLAGS[@]}" \
      --locations regionName=canadaeast failoverPriority=0 isZoneRedundant=False -o none
  fi
fi
if az cosmosdb sql database show -a "$COSMOS" -g "$RG" -n recipesdb -o none 2>/dev/null; then
  echo "  database recipesdb exists"
else
  # The database owns the throughput; containers must never have their own.
  TP=(--throughput 1000); $SERVERLESS && TP=()
  az cosmosdb sql database create -a "$COSMOS" -g "$RG" -n recipesdb "${TP[@]}" -o none
  echo "  database recipesdb created"
fi
for pair in recipes:/diet insights:/id reviews:/recipeId; do
  c=${pair%%:*}; pk=${pair#*:}
  if az cosmosdb sql container show -a "$COSMOS" -g "$RG" -d recipesdb -n "$c" -o none 2>/dev/null; then
    echo "  container $c exists"
  else
    az cosmosdb sql container create -a "$COSMOS" -g "$RG" -d recipesdb -n "$c" -p "$pk" -o none
    echo "  container $c created (partition key $pk)"
  fi
done

# ---------------------------------------------------------------- P2-2
step "P2-2 · Uploads storage account $UPLOADS"
if az storage account show -n "$UPLOADS" -g "$RG" -o none 2>/dev/null; then
  echo "  exists"
else
  az storage account create -n "$UPLOADS" -g "$RG" -l "$LOCATION" --kind StorageV2 --sku Standard_LRS \
    --allow-blob-public-access false -o none
  echo "  created"
fi
# container-rm is the management plane: no data role or key needed.
if az storage container-rm show --storage-account "$UPLOADS" -g "$RG" -n uploads -o none 2>/dev/null; then
  echo "  container uploads exists"
else
  az storage container-rm create --storage-account "$UPLOADS" -g "$RG" -n uploads -o none
  echo "  container uploads created"
fi
UPLOADS_ID=$(azq storage account show -n "$UPLOADS" -g "$RG" --query id -o tsv)

# ---------------------------------------------------------------- P2-3
step "P2-3 · Service Bus $SB (Basic) + queue reviews"
if az servicebus namespace show -n "$SB" -g "$RG" -o none 2>/dev/null; then
  echo "  exists"
else
  az servicebus namespace create -n "$SB" -g "$RG" -l "$LOCATION" --sku Basic -o none
  echo "  created"
fi
if az servicebus queue show --namespace-name "$SB" -g "$RG" -n reviews -o none 2>/dev/null; then
  echo "  queue reviews exists"
else
  az servicebus queue create --namespace-name "$SB" -g "$RG" -n reviews -o none
  echo "  queue reviews created"
fi
SB_ID=$(azq servicebus namespace show -n "$SB" -g "$RG" --query id -o tsv)

# ---------------------------------------------------------------- P2-4
step "P2-4 · Function App $FN (Flex Consumption, Node 24)"
if az functionapp show -n "$FN" -g "$RG" -o none 2>/dev/null; then
  echo "  exists"
else
  # The Function App's OWN storage (code, host state); uploads go to $UPLOADS.
  if ! az storage account show -n "$FN_STORAGE" -g "$RG" -o none 2>/dev/null; then
    az storage account create -n "$FN_STORAGE" -g "$RG" -l "$LOCATION" --kind StorageV2 --sku Standard_LRS \
      --allow-blob-public-access false -o none
  fi
  az functionapp create -n "$FN" -g "$RG" --storage-account "$FN_STORAGE" \
    --flexconsumption-location "$LOCATION" --runtime node --runtime-version 24 -o none
  echo "  created"
fi
az functionapp identity assign -n "$FN" -g "$RG" -o none
FN_ID=$(azq functionapp identity show -n "$FN" -g "$RG" --query principalId -o tsv)
FNHOST=$(azq functionapp show -n "$FN" -g "$RG" --query "defaultHostName || properties.defaultHostName" -o tsv)
echo "  identity: $FN_ID"
echo "  address:  https://$FNHOST"
# The brief wants Application Insights on. Flex normally creates it; make sure.
if [[ -z "$(azq functionapp config appsettings list -n "$FN" -g "$RG" --query "[?name=='APPLICATIONINSIGHTS_CONNECTION_STRING'].name | [0]" -o tsv)" ]]; then
  echo "  no Application Insights yet: creating $FN"
  LAW_ID=$(azq resource show -g "$RG" -n "law-cpsy300-$TEAM" --resource-type Microsoft.OperationalInsights/workspaces --query id -o tsv)
  az resource create -g "$RG" -n "$FN" -l "$LOCATION" --resource-type Microsoft.Insights/components \
    --api-version 2020-02-02 --properties "{\"Application_Type\":\"web\",\"WorkspaceResourceId\":\"$LAW_ID\"}" -o none
  AI_CS=$(azq resource show -g "$RG" -n "$FN" --resource-type Microsoft.Insights/components --query properties.ConnectionString -o tsv)
  az functionapp config appsettings set -n "$FN" -g "$RG" --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$AI_CS" -o none
fi

# ---------------------------------------------------------------- P2-5
step "P2-5 · Roles for the Function App's identity"
if [[ "$(azq cosmosdb sql role assignment list -g "$RG" --account-name "$COSMOS" --query "length([?principalId=='$FN_ID'])" -o tsv)" != "0" ]]; then
  echo "  Cosmos DB Built-in Data Contributor exists"
else
  for attempt in 1 2 3 4 5 6; do
    if az cosmosdb sql role assignment create -g "$RG" --account-name "$COSMOS" \
         --role-definition-id 00000000-0000-0000-0000-000000000002 --scope "/" --principal-id "$FN_ID" -o none 2>/dev/null; then
      echo "  Cosmos DB Built-in Data Contributor created"; break
    fi
    [[ $attempt -eq 6 ]] && die "Cosmos DB role assignment failed. Re-run the script in a minute."
    sleep 10
  done
fi
ensure_role "$FN_ID" "$UPLOADS_ID" "Storage Blob Data Owner"
ensure_role "$FN_ID" "$UPLOADS_ID" "Storage Queue Data Contributor"
ensure_role "$FN_ID" "$SB_ID"      "Azure Service Bus Data Receiver"

# ---------------------------------------------------------------- P2-6
step "P2-6 · Function App settings (addresses and managedidentity only, no keys)"
COSMOS_ENDPOINT=$(azq cosmosdb show -g "$RG" -n "$COSMOS" --query documentEndpoint -o tsv)
az functionapp config appsettings set -n "$FN" -g "$RG" --settings \
  "COSMOS_ENDPOINT=$COSMOS_ENDPOINT" \
  "UploadsStorage__blobServiceUri=https://$UPLOADS.blob.core.windows.net" \
  "UploadsStorage__queueServiceUri=https://$UPLOADS.queue.core.windows.net" \
  "UploadsStorage__credential=managedidentity" \
  "ServiceBusConnection__fullyQualifiedNamespace=$SB.servicebus.windows.net" \
  "ServiceBusConnection__credential=managedidentity" -o none
echo "  six settings written"

# ---------------------------------------------------------------- P2-7
step "P2-7 · Container app $APP: identity, Sender role, API_BASE_URL + SERVICEBUS_NAMESPACE"
APP_ID=$(azq containerapp identity assign -n "$APP" -g "$RG" --system-assigned --query principalId -o tsv)
ensure_role "$APP_ID" "$SB_ID" "Azure Service Bus Data Sender"
want_api="https://$FNHOST"; want_ns="$SB.servicebus.windows.net"
have_api=$(azq containerapp show -n "$APP" -g "$RG" --query "properties.template.containers[0].env[?name=='API_BASE_URL'].value | [0]" -o tsv)
have_ns=$(azq containerapp show -n "$APP" -g "$RG" --query "properties.template.containers[0].env[?name=='SERVICEBUS_NAMESPACE'].value | [0]" -o tsv)
if [[ "$have_api" == "$want_api" && "$have_ns" == "$want_ns" ]]; then
  echo "  env vars already set"
else
  # New revision; DASHBOARD_TITLE and the rest stay as they are.
  az containerapp update -n "$APP" -g "$RG" --container-name "$IMAGE_REPO" \
    --set-env-vars "API_BASE_URL=$want_api" "SERVICEBUS_NAMESPACE=$want_ns" -o none
  echo "  set (new revision)"
fi

# ---------------------------------------------------------------- P2-8
if $DEPLOY_API; then
  step "P2-8 · Deploy the API workflow on $GITHUB_REPO (main)"
  if gh workflow run deploy-api.yml -R "$GITHUB_REPO" --ref main 2>/dev/null; then
    sleep 8
    RUN_ID=$(gh run list -R "$GITHUB_REPO" --workflow deploy-api.yml --limit 1 --json databaseId -q '.[0].databaseId')
    gh run watch "$RUN_ID" -R "$GITHUB_REPO" --exit-status || die "Deploy the API failed: gh run view $RUN_ID -R $GITHUB_REPO --log-failed"
  else
    echo "  WARNING: could not start deploy-api.yml on main (is pull request 1 merged? are the secrets set?)."
  fi
fi

# ---------------------------------------------------------------- P2-9
step "P2-9 · Event Grid subscription uploads-to-processcsv"
echo "  waking the Function App ..."
curl -s -o /dev/null --max-time 60 "https://$FNHOST/api/insights" || true
KEY=""
for _ in $(seq 1 12); do
  KEY=$(azq functionapp keys list -n "$FN" -g "$RG" --query systemKeys.blobs_extension -o tsv 2>/dev/null || true)
  [[ -n "$KEY" && "$KEY" != "None" ]] && break
  KEY=""; sleep 10
done
if [[ -n "$(azq eventgrid system-topic event-subscription list -g "$RG" --system-topic-name uploads-events --query "[?name=='uploads-to-processcsv'].name | [0]" -o tsv 2>/dev/null)" ]]; then
  echo "  exists"
elif [[ -z "$KEY" ]]; then
  echo "  SKIPPED: no blobs_extension key yet, so processCsv is not deployed."
  echo "  Merge pull request 1 (or run with --deploy-api) and re-run this script."
else
  az eventgrid system-topic show -n uploads-events -g "$RG" -o none 2>/dev/null \
    || az eventgrid system-topic create -n uploads-events -g "$RG" \
         -l "$(azq storage account show -n "$UPLOADS" -g "$RG" --query location -o tsv)" \
         --topic-type microsoft.storage.storageaccounts --source "$UPLOADS_ID" -o none
  # The key is only ever passed to Azure here; it is not printed.
  az eventgrid system-topic event-subscription create -n uploads-to-processcsv -g "$RG" \
    --system-topic-name uploads-events --event-delivery-schema EventGridSchema \
    --endpoint-type webhook \
    --endpoint "https://$FNHOST/runtime/webhooks/blobs?functionName=Host.Functions.processCsv&code=$KEY" \
    --included-event-types Microsoft.Storage.BlobCreated \
    --subject-begins-with /blobServices/default/containers/uploads/blobs/ \
    --subject-ends-with .csv -o none
  echo "  created (Blob Created, uploads/*.csv only)"
fi

# ---------------------------------------------------------------- P2-10
if $UPLOAD_CSV; then
  step "P2-10 · Upload All_Diets.csv to $UPLOADS/uploads"
  CSV="$REPO_DIR/data/All_Diets.csv"; [[ -f "$CSV" ]] || CSV="$REPO_DIR/api/test/All_Diets.csv"
  [[ -f "$CSV" ]] || die "No All_Diets.csv found (looked in data/ and api/test/ under '$REPO_DIR')."
  # Your own account has no blob data role, so the CLI uses the account key for this one upload.
  az storage blob upload --account-name "$UPLOADS" -c uploads -f "$CSV" -n All_Diets.csv \
    --auth-mode key --overwrite -o none
  echo "  uploaded; processCsv takes a few minutes. Then:"
  echo "    curl https://$FNHOST/api/insights"
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

deploy.yml (E6) needs RESOURCE_GROUP: $RG and CONTAINERAPP: $APP
(it finds the registry, $ACR, by itself).

Phase 2:
  Function App:  https://$FNHOST   ($FN)
  Cosmos DB:     $COSMOS   Uploads: $UPLOADS   Service Bus: $SB
  Check:  curl https://$FNHOST/api/insights
          curl "https://$FNHOST/api/recipes?diet=keto&q=chicken"   (total 218)
  Still by hand: the saved KQL query (brief step 13) and the screenshots.

Still by hand: D5 (new revision with a different DASHBOARD_TITLE, screenshots),
E2 whoami workflow if your instructor wants to see it, E7 visible-change PR.
================================================================
EOF
