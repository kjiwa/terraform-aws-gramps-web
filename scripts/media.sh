#!/bin/sh
# Media storage hygiene for the Gramps Web media bucket.
#
# Gramps Web has no code path that removes a file from media storage: deleting
# or replacing a media object through the app only unlinks references and
# drops the DB row (gramps_webapi/api/resources/delete.py:delete_media). The
# S3 backend (gramps_webapi/api/s3.py) implements upload/get/head/list/presign
# and nothing else -- there is no delete, and no config toggle to add one.
# Every checksum ever uploaded, replaced, or deleted therefore stays in the
# bucket forever unless something else reclaims it. This is that something.
#
# It also normalizes media paths: Gramps Web writes <checksum>.<ext> for every
# upload (resources/media.py), but rows imported from a desktop database can
# carry the desktop's original relative path. `path` plays no part in S3
# storage or retrieval (objects are keyed by checksum); flattening just makes
# the DB uniform with what the app itself would have written.
#
# Talks to the app's own HTTP API for everything DB-related (never the database
# directly), so the search index and edit history stay correct, and to S3
# directly for the deletes the app has no endpoint for.
#
#   ./media.sh orphans           List S3 objects no media object references,
#                                 with total size. Changes nothing.
#   ./media.sh gc                Delete them, with a confirm prompt. A plain
#                                 delete on this versioned bucket leaves a
#                                 delete marker and pushes the prior version to
#                                 noncurrent, where the expire-noncurrent
#                                 lifecycle rule reaps it after 90 days -- a
#                                 free undo window on irreplaceable originals.
#   ./media.sh flatten           List legacy paths and the <checksum>.<ext>
#                                 they would become. Changes nothing.
#   ./media.sh flatten --apply   Rewrite them, with a confirm prompt.
#
# Env: ENV (default prod; selects terraform/config/stack/<env>), AWS_REGION
#      (default: primary_region from the env's tfvars), FORCE=1 (skip the
#      confirm prompts), MEDIA_USERNAME / MEDIA_PASSWORD (skip the login
#      prompts).
#
# The Gramps Web account used to log in must carry the ViewPrivate permission
# for every subcommand, and EditObject for flatten. ViewPrivate matters even
# for orphans/gc, which never touch a media object through the app: without
# it the app hands back a private-filtered database (api/util.py), private
# media go missing from the reference count, and their still-live S3 objects
# would be misread as orphans.
set -eu

SCRIPT_DIR="$(
  unset CDPATH
  cd -- "$(dirname -- "$0")" && pwd
)"
readonly SCRIPT_DIR
REPO_ROOT="$(dirname -- "$SCRIPT_DIR")"
readonly REPO_ROOT

readonly LOG_PREFIX="media"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

TAB="$(printf '\t')"
readonly TAB

# The permission claims the Gramps Web API stamps into the JWT (auth/const.py:
# PERM_VIEW_PRIVATE / PERM_EDIT_OBJ). Not configurable -- they are the API's
# own vocabulary.
readonly PERM_VIEW_PRIVATE="ViewPrivate"
readonly PERM_EDIT_OBJ="EditObject"

# Cross-function state: TOKEN/USERNAME/PASSWORD are set once by
# get_credentials/login and read by every api_call thereafter.
TOKEN=""
USERNAME=""
PASSWORD=""

usage() {
  echo "usage: $0 orphans|gc|flatten [--apply]" >&2
  exit 2
}

# -> the media bucket name: the explicit tfvars value if set, else the
# derived name modules/storage/main.tf falls back to. Mirrors that
# module's locals.media_bucket_name exactly.
media_bucket_name() {
  local name
  name="$(sed -n \
    's/^[[:space:]]*media_bucket_name[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$TFVARS" 2>/dev/null | head -n 1)"
  if [ -n "$name" ]; then
    echo "$name"
  else
    echo "gramps-web-media-$(resolve_account)"
  fi
}

# in_list ITEM "a b c": ITEM is one of the space-separated words. Same idiom
# as clean-amis.sh; fine at this bucket's scale (low hundreds of objects).
in_list() {
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# --- Gramps Web API client ----------------------------------------------------

# api_login BODY -> "response-body\nhttp-status", unauthenticated (the token
# endpoint is how TOKEN gets set in the first place).
api_login() {
  curl -sS -w '\n%{http_code}' -X POST "$API/token/" \
    -H "Content-Type: application/json" --data "$1"
}

# api_call METHOD PATH [BODY] -> "response-body\nhttp-status". Requires
# $TOKEN. PATH is relative to $API.
api_call() {
  local method path data
  method="$1"
  path="$2"
  data="${3:-}"
  if [ -n "$data" ]; then
    curl -sS -w '\n%{http_code}' -X "$method" "$API$path" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      --data "$data"
  else
    curl -sS -w '\n%{http_code}' -X "$method" "$API$path" \
      -H "Authorization: Bearer $TOKEN"
  fi
}

# check_response "body\nstatus" CONTEXT -> the body on stdout for a 2xx
# status; dies with the body as detail otherwise.
check_response() {
  local body status
  body="$(printf '%s\n' "$1" | sed '$d')"
  status="$(printf '%s\n' "$1" | tail -n 1)"
  case "$status" in
  2??) printf '%s\n' "$body" ;;
  *) die "$2 -> HTTP $status: $body" ;;
  esac
}

# media_list KEYS -> the JSON array from GET /media/?keys=KEYS (all objects;
# the endpoint returns everything when no page is requested).
media_list() {
  check_response "$(api_call GET "/media/?keys=$1")" "GET /media/?keys=$1"
}

# jwt_claims TOKEN -> its payload claims as JSON. Decodes the base64url
# segment by hand (tr to base64 alphabet, pad to a multiple of 4); openssl's
# decoder is used because base64(1)'s decode flag differs between BSD and GNU
# (-D vs -d), while `openssl base64 -d -A` is the same on both.
jwt_claims() {
  local payload rem
  payload="$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')"
  rem=$((${#payload} % 4))
  case "$rem" in
  2) payload="${payload}==" ;;
  3) payload="${payload}=" ;;
  1) die "malformed access token" ;;
  esac
  printf '%s' "$payload" | openssl base64 -d -A 2>/dev/null
}

# require_app_permissions PERM...: die unless every PERM is in the current
# token's `permissions` claim.
require_app_permissions() {
  local claims perm
  claims="$(jwt_claims "$TOKEN")"
  [ -n "$claims" ] || die "could not decode the access token"
  for perm in "$@"; do
    printf '%s' "$claims" | jq -e --arg p "$perm" \
      '(.permissions // []) | index($p) != null' >/dev/null ||
      die "the '$USERNAME' account lacks the '$perm' permission this command needs"
  done
}

# read_password PROMPT -> the entered value, terminal echo suppressed.
read_password() {
  local pass
  printf '%s' "$1" >&2
  stty -echo 2>/dev/null
  trap 'stty echo 2>/dev/null' EXIT INT TERM
  read -r pass
  stty echo 2>/dev/null
  trap - EXIT INT TERM
  echo >&2
  printf '%s' "$pass"
}

get_credentials() {
  USERNAME="${MEDIA_USERNAME:-}"
  if [ -z "$USERNAME" ]; then
    printf '[%s] Gramps Web username: ' "$LOG_PREFIX" >&2
    read -r USERNAME
  fi
  PASSWORD="${MEDIA_PASSWORD:-}"
  [ -n "$PASSWORD" ] || PASSWORD="$(read_password "[$LOG_PREFIX] Gramps Web password: ")"
  [ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || die "username and password are required"
}

login() {
  local body
  body="$(jq -n --arg u "$USERNAME" --arg p "$PASSWORD" '{username:$u,password:$p}')"
  TOKEN="$(check_response "$(api_login "$body")" "login" | jq -r '.access_token')"
  [ -n "$TOKEN" ] && [ "$TOKEN" != null ] ||
    die "login succeeded but the response had no access_token"
}

# --- orphans / gc --------------------------------------------------------------

# -> every referenced checksum, space-joined (in_list's expected form).
build_db_checksum_set() {
  local checksums
  checksums="$(media_list checksum | jq -r '.[].checksum')"
  # shellcheck disable=SC2086,SC2116 # unquoted echo collapses newlines to spaces
  echo $checksums
}

# list_orphans DB_SET -> "key<TAB>size" lines for S3 objects not in DB_SET.
list_orphans() {
  local db_set kv
  db_set="$1"
  kv="$(aws --region "$REGION" s3api list-objects-v2 --bucket "$BUCKET" \
    --query 'Contents[].[Key,Size]' --output text)"
  [ "$kv" != "None" ] || return 0
  printf '%s\n' "$kv" | while IFS="$TAB" read -r key size; do
    [ -n "$key" ] || continue
    in_list "$key" "$db_set" || printf '%s\t%s\n' "$key" "$size"
  done
}

cmd_orphans() {
  local orphans count total
  orphans="$(list_orphans "$(build_db_checksum_set)")"
  if [ -z "$orphans" ]; then
    log "no orphaned objects."
    return 0
  fi
  printf '%s\n' "$orphans" | while IFS="$TAB" read -r key size; do
    [ -n "$key" ] || continue
    log "ORPHAN $key  ($size bytes)"
  done
  count="$(printf '%s\n' "$orphans" | grep -c .)"
  total="$(printf '%s\n' "$orphans" | awk -F"$TAB" '{s+=$2} END{print s+0}')"
  log "$count orphaned object(s), $total bytes total. Re-run with 'gc' to delete them."
}

cmd_gc() {
  local orphans
  orphans="$(list_orphans "$(build_db_checksum_set)")"
  if [ -z "$orphans" ]; then
    log "no orphaned objects; nothing to delete."
    return 0
  fi
  printf '%s\n' "$orphans" | while IFS="$TAB" read -r key size; do
    [ -n "$key" ] || continue
    log "DELETE $key  ($size bytes)"
  done
  confirm "Delete the objects marked DELETE above from s3://$BUCKET? (versioning + expire-noncurrent give a 90-day undo window)"
  printf '%s\n' "$orphans" | while IFS="$TAB" read -r key size; do
    [ -n "$key" ] || continue
    log "deleting $key..."
    aws --region "$REGION" s3api delete-object --bucket "$BUCKET" --key "$key" >/dev/null
  done
  log "done."
}

# --- flatten -------------------------------------------------------------------

# canonical_path CHECKSUM PATH -> CHECKSUM with PATH's extension (or bare
# CHECKSUM if PATH has none). Extension is read off the existing path rather
# than derived from mime, to avoid reimplementing upstream's MIME table.
canonical_path() {
  case "$2" in
  *.*) printf '%s.%s\n' "$1" "${2##*.}" ;;
  *) printf '%s\n' "$1" ;;
  esac
}

# plan_renames ROWS: ROWS is "handle<TAB>checksum<TAB>path" lines (media_list's
# output, reshaped). Logs each planned rename and prints "handle<TAB>new_path"
# lines for rows not already in canonical form.
plan_renames() {
  local handle checksum path new_path
  printf '%s\n' "$1" | while IFS="$TAB" read -r handle checksum path; do
    [ -n "$handle" ] || continue
    new_path="$(canonical_path "$checksum" "$path")"
    [ "$path" != "$new_path" ] || continue
    log "RENAME $path -> $new_path  (handle $handle)"
    printf '%s\t%s\n' "$handle" "$new_path"
  done
}

# rewrite_path HANDLE NEW_PATH: read-modify-write, since PUT /media/<handle>
# replaces the whole object (resources/base.py). Only `path` changes; every
# other field round-trips as the API returned it.
rewrite_path() {
  local obj new_obj
  obj="$(check_response "$(api_call GET "/media/$1")" "GET /media/$1")"
  new_obj="$(printf '%s' "$obj" | jq --arg p "$2" '.path = $p')"
  check_response "$(api_call PUT "/media/$1" "$new_obj")" "PUT /media/$1" >/dev/null
}

cmd_flatten() {
  local apply rows renames count
  apply="$1"
  rows="$(media_list "handle,checksum,path" | jq -r '.[] | [.handle,.checksum,.path] | @tsv')"
  renames="$(plan_renames "$rows")"
  if [ -z "$renames" ]; then
    log "no legacy paths; nothing to flatten."
    return 0
  fi
  count="$(printf '%s\n' "$renames" | grep -c .)"
  if [ "$apply" != 1 ]; then
    log "$count path(s) would be rewritten. Re-run with 'flatten --apply' to apply."
    return 0
  fi
  confirm "Rewrite the $count path(s) listed above?"
  printf '%s\n' "$renames" | while IFS="$TAB" read -r handle new_path; do
    [ -n "$handle" ] || continue
    log "rewriting $handle -> $new_path..."
    rewrite_path "$handle" "$new_path"
  done
  log "done."
}

main() {
  local cmd apply_flag
  cmd="${1:-}"
  apply_flag=0
  case "$cmd" in
  orphans | gc)
    [ "$#" -eq 1 ] || usage
    ;;
  flatten)
    case "${2:-}" in
    '') ;;
    --apply) apply_flag=1 ;;
    *) usage ;;
    esac
    [ "$#" -le 2 ] || usage
    ;;
  *) usage ;;
  esac

  require aws jq curl openssl
  env_paths
  REGION="$(resolve_region "$TFVARS")"
  readonly REGION
  BUCKET="$(media_bucket_name)"
  readonly BUCKET
  DOMAIN="$(sed -n \
    's/^[[:space:]]*primary_domain[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$TFVARS" | head -n 1)"
  [ -n "$DOMAIN" ] || die "no primary_domain set in $TFVARS"
  readonly DOMAIN
  API="https://$DOMAIN/api"
  readonly API

  get_credentials
  login

  case "$cmd" in
  orphans)
    require_app_permissions "$PERM_VIEW_PRIVATE"
    cmd_orphans
    ;;
  gc)
    require_app_permissions "$PERM_VIEW_PRIVATE"
    cmd_gc
    ;;
  flatten)
    require_app_permissions "$PERM_VIEW_PRIVATE" "$PERM_EDIT_OBJ"
    cmd_flatten "$apply_flag"
    ;;
  esac
}

main "$@"
