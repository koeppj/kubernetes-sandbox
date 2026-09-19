#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${NFS_WORKLOAD_STATE_FILE:-${SCRIPT_DIR}/.nfs-workload-replicas.tsv}"
TIMEOUT="${NFS_SHUTDOWN_TIMEOUT:-5m}"
DRY_RUN=false
KUBECTL=(microk8s kubectl)

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--state-file PATH] [--timeout DURATION]

Gracefully scale every Deployment and StatefulSet that mounts an NFS-backed
PVC to zero. The current replica counts are saved for restore-nfs-workloads.sh.

Options:
  --dry-run          Print the detected workloads without changing the cluster.
  --state-file PATH  Override the replica state file (default: ${STATE_FILE}).
  --timeout VALUE    Maximum wait for each workload to stop (default: ${TIMEOUT}).
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
command -v timeout >/dev/null 2>&1 || {
  echo "timeout is required but was not found in PATH." >&2
  exit 1
}

if [[ "$DRY_RUN" == false && -e "$STATE_FILE" ]]; then
  echo "Replica state already exists: $STATE_FILE" >&2
  echo "Run restore-nfs-workloads.sh first, or explicitly choose another --state-file." >&2
  exit 1
fi

declare -A nfs_storage_classes=()
declare -A nfs_claims=()
declare -A targets=()

storage_class_rows="$("${KUBECTL[@]}" get storageclasses -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{.provisioner}}{{"\n"}}{{end}}')"
while IFS=$'\t' read -r storage_class provisioner; do
  [[ -n "$storage_class" ]] || continue
  if [[ "${provisioner,,}" == *nfs* ]]; then
    nfs_storage_classes["$storage_class"]=1
  fi
done <<< "$storage_class_rows"

if ((${#nfs_storage_classes[@]} == 0)); then
  echo "No NFS-provisioned StorageClasses were found; nothing to shut down."
  exit 0
fi

pvc_rows="$("${KUBECTL[@]}" get persistentvolumeclaims --all-namespaces -o go-template='{{range .items}}{{.metadata.namespace}}{{"\t"}}{{.metadata.name}}{{"\t"}}{{.spec.storageClassName}}{{"\n"}}{{end}}')"
while IFS=$'\t' read -r namespace claim storage_class; do
  [[ -n "$namespace" && -n "$claim" ]] || continue
  if [[ -n "$storage_class" && -n "${nfs_storage_classes[$storage_class]:-}" ]]; then
    nfs_claims["${namespace}/${claim}"]=1
  fi
done <<< "$pvc_rows"

workload_rows="$("${KUBECTL[@]}" get deployments.apps,statefulsets.apps --all-namespaces -o go-template='{{range .items}}{{$kind := .kind}}{{$namespace := .metadata.namespace}}{{$name := .metadata.name}}{{$replicas := .spec.replicas}}{{range .spec.template.spec.volumes}}{{if .persistentVolumeClaim}}{{printf "%s\t%s\t%s\t%d\tclaim\t%s\n" $kind $namespace $name $replicas .persistentVolumeClaim.claimName}}{{end}}{{end}}{{range .spec.volumeClaimTemplates}}{{printf "%s\t%s\t%s\t%d\tclass\t%s\n" $kind $namespace $name $replicas .spec.storageClassName}}{{end}}{{end}}')"

while IFS=$'\t' read -r kind namespace name replicas reference_type reference; do
  [[ -n "$kind" && -n "$namespace" && -n "$name" ]] || continue

  uses_nfs=false
  case "$reference_type" in
    claim)
      [[ -n "${nfs_claims["${namespace}/${reference}"]:-}" ]] && uses_nfs=true
      ;;
    class)
      [[ -n "$reference" && -n "${nfs_storage_classes[$reference]:-}" ]] && uses_nfs=true
      ;;
  esac

  if [[ "$uses_nfs" == true ]]; then
    case "$kind" in
      Deployment) resource_kind=deployment ;;
      StatefulSet) resource_kind=statefulset ;;
      *) continue ;;
    esac
    targets["${resource_kind}|${namespace}|${name}"]="$replicas"
  fi
done <<< "$workload_rows"

if ((${#targets[@]} == 0)); then
  echo "No Deployments or StatefulSets currently reference NFS-backed PVCs."
  exit 0
fi

mapfile -t target_keys < <(printf '%s\n' "${!targets[@]}" | sort)

echo "NFS StorageClasses:"
printf '  %s\n' "${!nfs_storage_classes[@]}" | sort
echo
echo "NFS-backed workloads and saved replica counts:"
for key in "${target_keys[@]}"; do
  IFS='|' read -r resource_kind namespace name <<< "$key"
  printf '  %-11s %s/%s: %s\n' "$resource_kind" "$namespace" "$name" "${targets[$key]}"
done

if [[ "$DRY_RUN" == true ]]; then
  echo
  echo "Dry run only; no workloads were changed and no state file was written."
  exit 0
fi

state_dir="$(dirname "$STATE_FILE")"
mkdir -p "$state_dir"
umask 077
state_temp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
trap 'rm -f -- "$state_temp"' EXIT

{
  echo "# nfs-workload-replica-state-v1"
  printf '# created-at\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# kind namespace name replicas"
  for key in "${target_keys[@]}"; do
    IFS='|' read -r resource_kind namespace name <<< "$key"
    printf '%s\t%s\t%s\t%s\n' "$resource_kind" "$namespace" "$name" "${targets[$key]}"
  done
} > "$state_temp"
mv "$state_temp" "$STATE_FILE"
trap - EXIT

scale_kind_to_zero() {
  local requested_kind="$1"
  local key resource_kind namespace name replicas

  for key in "${target_keys[@]}"; do
    IFS='|' read -r resource_kind namespace name <<< "$key"
    [[ "$resource_kind" == "$requested_kind" ]] || continue
    replicas="${targets[$key]}"
    if [[ "$replicas" == "0" ]]; then
      echo "Already stopped: ${resource_kind} ${namespace}/${name}"
      continue
    fi
    echo "Scaling ${resource_kind} ${namespace}/${name} from ${replicas} to 0..."
    "${KUBECTL[@]}" scale "$resource_kind/$name" --namespace "$namespace" --replicas=0
  done

  for key in "${target_keys[@]}"; do
    IFS='|' read -r resource_kind namespace name <<< "$key"
    [[ "$resource_kind" == "$requested_kind" ]] || continue
    replicas="${targets[$key]}"
    [[ "$replicas" != "0" ]] || continue
    wait_for_zero_replicas "$resource_kind" "$namespace" "$name"
  done
}

wait_for_zero_replicas() {
  local resource_kind="$1"
  local namespace="$2"
  local name="$3"
  local wait_status

  if timeout --foreground "$TIMEOUT" bash -c '
    resource_kind="$1"
    namespace="$2"
    name="$3"
    shift 3

    while true; do
      status_replicas="$("$@" get "$resource_kind/$name" \
        --namespace "$namespace" \
        -o jsonpath="{.status.replicas}")" || exit 1

      # Kubernetes omits zero-valued status fields when serializing the object.
      if [[ -z "$status_replicas" || "$status_replicas" == "0" ]]; then
        exit 0
      fi

      sleep 1
    done
  ' _ "$resource_kind" "$namespace" "$name" "${KUBECTL[@]}"; then
    return 0
  else
    wait_status=$?
  fi

  if [[ "$wait_status" == "124" ]]; then
    echo "Timed out waiting for ${resource_kind} ${namespace}/${name} to stop." >&2
  fi
  return "$wait_status"
}

# Stop application front ends before stateful data services such as Postgres.
scale_kind_to_zero deployment
scale_kind_to_zero statefulset

echo
echo "All detected NFS-backed Deployments and StatefulSets are stopped."
echo "Replica state saved to: $STATE_FILE"
echo "It is now safe to begin NFS maintenance."
