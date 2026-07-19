#!/usr/bin/env bash

set -Eeuo pipefail

ENV_FILE="${ENV_FILE:-/etc/registry-cleanup.env}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
fi

REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-}"
REGISTRY_URL="${REGISTRY_URL:-}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
REGISTRY_CONFIG="${REGISTRY_CONFIG:-/etc/docker/registry/config.yml}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:-}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-}"
KEEP_PRODUCTION="${KEEP_PRODUCTION:-3}"
DRY_RUN="${DRY_RUN:-false}"
REGISTRY_WAS_STOPPED=false
PROTECTED_TAGS=("latest" "develop")

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
  log "ERROR: $*" >&2
}

check_dependencies() {
  local dependencies=(curl jq docker awk sort grep)
  local dependency

  for dependency in "${dependencies[@]}"; do
    command -v "${dependency}" >/dev/null 2>&1 || {
      error "Không tìm thấy command: ${dependency}"
      exit 1
    }
  done

  [[ -n "${REGISTRY_CONTAINER}" ]] || {
    error "REGISTRY_CONTAINER chưa được cấu hình"
    exit 1
  }

  [[ "${KEEP_PRODUCTION}" =~ ^[0-9]+$ ]] || {
    error "KEEP_PRODUCTION phải là số nguyên không âm"
    exit 1
  }
}

resolve_registry_url() {
  if [[ -n "${REGISTRY_URL}" ]]; then
    REGISTRY_URL="${REGISTRY_URL%/}"
    return
  fi

  local registry_ip
  registry_ip="$(
    docker inspect \
      --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
      "${REGISTRY_CONTAINER}" 2>/dev/null |
      awk 'NF { print; exit }'
  )"

  [[ -n "${registry_ip}" ]] || {
    error "Không lấy được IP của container ${REGISTRY_CONTAINER}"
    exit 1
  }

  REGISTRY_URL="http://${registry_ip}:${REGISTRY_PORT}"
}

registry_curl() {
  local curl_args=(
    --fail-with-body
    --silent
    --show-error
    --connect-timeout 10
    --max-time 120
  )

  if [[ -n "${REGISTRY_USERNAME}" ]]; then
    curl_args+=(--user "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}")
  fi

  curl "${curl_args[@]}" "$@"
}

check_registry_connection() {
  log "Kiểm tra kết nối Registry"

  registry_curl "${REGISTRY_URL}/v2/" >/dev/null || {
    error "Không kết nối được Registry tại ${REGISTRY_URL}"
    exit 1
  }

  log "Kết nối Registry thành công"
}

get_catalog() {
  local response

  response="$(registry_curl "${REGISTRY_URL}/v2/_catalog")" || {
    error "Không lấy được danh sách repository"
    return 1
  }

  jq -e '.repositories | type == "array"' >/dev/null 2>&1 <<<"${response}" || {
    error "Response catalog không hợp lệ"
    printf '%s\n' "${response}" >&2
    return 1
  }

  jq -r '.repositories[]?' <<<"${response}"
}

get_tags() {
  local repository="$1"
  local response

  response="$(registry_curl "${REGISTRY_URL}/v2/${repository}/tags/list")" || {
    error "Không lấy được tags của repository ${repository}"
    return 1
  }

  jq -e '(.tags == null) or (.tags | type == "array")' >/dev/null 2>&1 <<<"${response}" || {
    error "Response tags không hợp lệ: ${repository}"
    return 1
  }

  jq -r '.tags[]?' <<<"${response}"
}

get_manifest_digest() {
  local repository="$1"
  local reference="$2"

  registry_curl \
    --head \
    --header 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json' \
    "${REGISTRY_URL}/v2/${repository}/manifests/${reference}" |
    tr -d '\r' |
    awk 'tolower($1) == "docker-content-digest:" { print $2; exit }'
}

get_manifest_json() {
  local repository="$1"
  local reference="$2"

  registry_curl \
    --header 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json' \
    "${REGISTRY_URL}/v2/${repository}/manifests/${reference}"
}

get_created_at() {
  local repository="$1"
  local tag="$2"
  local manifest config_digest config_json created_at

  manifest="$(get_manifest_json "${repository}" "${tag}")" || return 1
  config_digest="$(jq -r '.config.digest // empty' <<<"${manifest}")"
  [[ -n "${config_digest}" ]] || return 1

  config_json="$(registry_curl "${REGISTRY_URL}/v2/${repository}/blobs/${config_digest}")" || return 1
  created_at="$(jq -r '.created // empty' <<<"${config_json}")"
  [[ -n "${created_at}" ]] || return 1

  printf '%s\n' "${created_at}"
}

array_contains() {
  local expected="$1"
  shift
  local item

  for item in "$@"; do
    [[ "${item}" == "${expected}" ]] && return 0
  done

  return 1
}

is_protected_tag() {
  array_contains "$1" "${PROTECTED_TAGS[@]}"
}

delete_manifest() {
  local repository="$1"
  local digest="$2"
  local tag="$3"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Sẽ xoá ${repository}:${tag} (${digest})"
    return 0
  fi

  registry_curl \
    --request DELETE \
    "${REGISTRY_URL}/v2/${repository}/manifests/${digest}" \
    >/dev/null || {
      error "Không xoá được ${repository}:${tag} (${digest})"
      return 1
    }

  log "Đã xoá ${repository}:${tag}"
}

cleanup_repository() {
  local repository="$1"
  local tags_output tag digest created_at record remaining
  local production_count delete_count deleted_count=0
  local -a protected_digests=()
  local -a production_records=()
  local -a deleted_digests=()

  log "----------------------------------------"
  log "Kiểm tra repository: ${repository}"

  tags_output="$(get_tags "${repository}")" || return 1

  if [[ -z "${tags_output}" ]]; then
    log "${repository}: không có tag"
    return 0
  fi

  while IFS= read -r tag; do
    [[ -n "${tag}" ]] || continue
    is_protected_tag "${tag}" || continue

    digest="$(get_manifest_digest "${repository}" "${tag}" || true)"
    [[ -n "${digest}" ]] || continue

    array_contains "${digest}" "${protected_digests[@]}" || protected_digests+=("${digest}")
    log "Bảo vệ ${repository}:${tag}"
  done <<<"${tags_output}"

  while IFS= read -r tag; do
    [[ -n "${tag}" ]] || continue

    case "${tag}" in
      production-*)
        digest="$(get_manifest_digest "${repository}" "${tag}" || true)"
        [[ -n "${digest}" ]] || continue
        created_at="$(get_created_at "${repository}" "${tag}" || true)"
        production_records+=("${created_at:-1970-01-01T00:00:00Z}|${tag}|${digest}")
        ;;
      latest|develop)
        ;;
      *)
        log "Bỏ qua tag ngoài rule: ${repository}:${tag}"
        ;;
    esac
  done <<<"${tags_output}"

  production_count="${#production_records[@]}"
  log "${repository}: ${production_count} production tag"

  if (( production_count <= KEEP_PRODUCTION )); then
    log "${repository}: không cần xoá"
    return 0
  fi

  delete_count=$((production_count - KEEP_PRODUCTION))

  while IFS= read -r record; do
    [[ -n "${record}" ]] || continue
    (( deleted_count >= delete_count )) && break

    remaining="${record#*|}"
    tag="${remaining%%|*}"
    digest="${remaining#*|}"

    if array_contains "${digest}" "${protected_digests[@]}"; then
      log "Giữ ${repository}:${tag} vì digest đang được latest/develop sử dụng"
      continue
    fi

    if array_contains "${digest}" "${deleted_digests[@]}"; then
      continue
    fi

    if delete_manifest "${repository}" "${digest}" "${tag}"; then
      deleted_digests+=("${digest}")
      deleted_count=$((deleted_count + 1))
    fi
  done < <(printf '%s\n' "${production_records[@]}" | sort -t'|' -k1,1)
}

cleanup_all_repositories() {
  local repositories repository failed_count=0 repository_count=0

  log "Đang lấy danh sách repository"
  repositories="$(get_catalog)" || return 1

  while IFS= read -r repository; do
    [[ -n "${repository}" ]] || continue
    repository_count=$((repository_count + 1))

    cleanup_repository "${repository}" || {
      failed_count=$((failed_count + 1))
      error "Cleanup repository thất bại: ${repository}"
    }
  done <<<"${repositories}"

  log "Đã kiểm tra ${repository_count} repository"
  (( failed_count == 0 ))
}

restore_registry() {
  [[ "${REGISTRY_WAS_STOPPED}" == "true" ]] || return 0
  log "Khởi động lại Registry sau lỗi"
  docker start "${REGISTRY_CONTAINER}" >/dev/null 2>&1 || true
  REGISTRY_WAS_STOPPED=false
}

run_garbage_collection() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY RUN] Bỏ qua garbage collection"
    return 0
  fi

  local registry_image registry_binary

  registry_image="$(docker inspect --format '{{.Config.Image}}' "${REGISTRY_CONTAINER}" 2>/dev/null)"
  registry_binary="$(docker exec "${REGISTRY_CONTAINER}" sh -c 'command -v registry || command -v docker-registry || true')"

  [[ -n "${registry_image}" ]] || {
    error "Không xác định được image Registry"
    return 1
  }

  [[ -n "${registry_binary}" ]] || {
    error "Không tìm thấy binary Registry"
    return 1
  }

  log "Dừng Registry để chạy garbage collection"
  docker stop "${REGISTRY_CONTAINER}" >/dev/null || return 1
  REGISTRY_WAS_STOPPED=true

  docker run \
    --rm \
    --volumes-from "${REGISTRY_CONTAINER}" \
    --entrypoint "${registry_binary}" \
    "${registry_image}" \
    garbage-collect \
    --delete-untagged \
    "${REGISTRY_CONFIG}" || {
      error "Garbage collection thất bại"
      return 1
    }

  docker start "${REGISTRY_CONTAINER}" >/dev/null || return 1
  REGISTRY_WAS_STOPPED=false
  log "Garbage collection hoàn tất"
}

main() {
  check_dependencies
  resolve_registry_url
  trap restore_registry EXIT

  log "Bắt đầu cleanup Docker Registry"
  log "Registry URL: ${REGISTRY_URL}"
  log "Registry container: ${REGISTRY_CONTAINER}"
  log "Giữ production: ${KEEP_PRODUCTION}"
  log "Dry run: ${DRY_RUN}"

  check_registry_connection
  cleanup_all_repositories || exit 1
  run_garbage_collection || exit 1

  log "Cleanup hoàn tất"
}

main "$@"
