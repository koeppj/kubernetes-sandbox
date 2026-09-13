#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${NFS_WORKLOAD_STATE_FILE:-${SCRIPT_DIR}/.nfs-workload-replicas.tsv}"
TIMEOUT="${NFS_RESTORE_TIMEOUT:-10m}"
DRY_RUN=false
KUBECTL=(microk8s kubectl)

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--state-file PATH] [--timeout DURATION]

Restore the replica counts saved by shutdown-nfs-workloads.sh. StatefulSets
are restored and made ready before dependent Deployments are started.

Options:
  --dry-run          Print the restore operations without changing the cluster.
  --state-file PATH  Override the replica state file (default: ${STATE_FILE}).
  --timeout VALUE    Rollout timeout accepted by kubectl (default: ${TIMEOUT}).
  -h, --help         Show this help.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --state-file)
      [[ $# -ge 2 ]] || { echo "Missing value for --state-file" >&2; exit 2; }
      STATE_FILE="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "Missing value for --timeout" >&2; exit 2; }
      TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v microk8s >/dev/null 2>&1 || {
  echo "microk8s is required but was not found in PATH." >&2
  exit 1
}

if [[ ! -f "$STATE_FILE" ]]; then
  echo "Replica state file was not found: $STATE_FILE" >&2
  echo "Run shutdown-nfs-workloads.sh first, or supply the matching --state-file." >&2
  exit 1
fi

if [[ "$(head -n 1 "$STATE_FILE")" != "# nfs-workload-replica-state-v1" ]]; then
  echo "Unrecognized replica state format: $STATE_FILE" >&2
  exit 1
fi

declare -A targets=()
while IFS=$'\t' read -r resource_kind namespace name replicas extra; do
  [[ -n "$resource_kind" && "${resource_kind:0:1}" != "#" ]] || continue
  if [[ "$resource_kind" != "deployment" && "$resource_kind" != "statefulset" ]]; then
    echo "Invalid workload kind in $STATE_FILE: $resource_kind" >&2
    exit 1
  fi
  if [[ -z "$namespace" || -z "$name" || ! "$replicas" =~ ^[0-9]+$ || -n "${extra:-}" ]]; then
    echo "Invalid replica state row in $STATE_FILE: $resource_kind $namespace $name $replicas" >&2
    exit 1
  fi
  targets["${resource_kind}|${namespace}|${name}"]="$replicas"
done < "$STATE_FILE"

if ((${#targets[@]} == 0)); then
  echo "Replica state contains no workloads: $STATE_FILE" >&2
  exit 1
fi

mapfile -t target_keys < <(printf '%s\n' "${!targets[@]}" | sort)

# Validate the whole restore set before changing any workload.
for key in "${target_keys[@]}"; do
  IFS='|' read -r resource_kind namespace name <<< "$key"
  "${KUBECTL[@]}" get "$resource_kind/$name" --namespace "$namespace" >/dev/null
done

echo "Replica counts to restore from $STATE_FILE:"
for requested_kind in statefulset deployment; do
  for key in "${target_keys[@]}"; do
    IFS='|' read -r resource_kind namespace name <<< "$key"
    [[ "$resource_kind" == "$requested_kind" ]] || continue
    printf '  %-11s %s/%s: %s\n' "$resource_kind" "$namespace" "$name" "${targets[$key]}"
  done
done

if [[ "$DRY_RUN" == true ]]; then
  echo
  echo "Dry run only; no workloads were changed and the state file was retained."
  exit 0
fi

restore_kind() {
  local requested_kind="$1"
  local key resource_kind namespace name replicas

  for key in "${target_keys[@]}"; do
    IFS='|' read -r resource_kind namespace name <<< "$key"
    [[ "$resource_kind" == "$requested_kind" ]] || continue
    replicas="${targets[$key]}"
    if [[ "$replicas" == "0" ]]; then
      echo "Leaving ${resource_kind} ${namespace}/${name} at its saved count of 0."
      continue
    fi
    echo "Scaling ${resource_kind} ${namespace}/${name} to ${replicas}..."
    "${KUBECTL[@]}" scale "$resource_kind/$name" --namespace "$namespace" --replicas="$replicas"
  done

  for key in "${target_keys[@]}"; do
    IFS='|' read -r resource_kind namespace name <<< "$key"
    [[ "$resource_kind" == "$requested_kind" ]] || continue
    replicas="${targets[$key]}"
    [[ "$replicas" != "0" ]] || continue
    "${KUBECTL[@]}" rollout status "$resource_kind/$name" --namespace "$namespace" --timeout="$TIMEOUT"
  done
}

# Start stateful data services before application front ends that depend on them.
restore_kind statefulset
restore_kind deployment

rm -f -- "$STATE_FILE"

echo
echo "All saved NFS-backed workload replica counts were restored."
echo "Removed completed replica state: $STATE_FILE"
