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
# Root: --root DIR, or $GRAMPS_WEB_ROOT, is the Terraform root that
#       instantiates the module (see common.sh). Place it before the subcommand.
# Env:  FORCE=1 (skip the confirm prompts), MEDIA_USERNAME / MEDIA_PASSWORD
#       (skip the login prompts).
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

readonly LOG_PREFIX="media"
# shellcheck source=keel/common.sh
. "$SCRIPT_DIR/keel/common.sh"
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
  echo "usage: $0 [--root DIR] orphans|gc|flatten [--apply]" >&2
  exit 2
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
  _api_call_method="$1"
  _api_call_path="$2"
  _api_call_data="${3:-}"
  if [ -n "$_api_call_data" ]; then
    curl -sS -w '\n%{http_code}' -X "$_api_call_method" "$API$_api_call_path" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      --data "$_api_call_data"
  else
    curl -sS -w '\n%{http_code}' -X "$_api_call_method" "$API$_api_call_path" \
      -H "Authorization: Bearer $TOKEN"
  fi
}

# check_response "body\nstatus" CONTEXT -> the body on stdout for a 2xx
# status; dies with the body as detail otherwise.
check_response() {
  _check_response_body="$(printf '%s\n' "$1" | sed '$d')"
  _check_response_status="$(printf '%s\n' "$1" | tail -n 1)"
  case "$_check_response_status" in
  2??) printf '%s\n' "$_check_response_body" ;;
  *) die "$2 -> HTTP $_check_response_status: $_check_response_body" ;;
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
  _jwt_claims_payload="$(printf '%s' "$1" | cut -d. -f2 | tr '_-' '/+')"
  _jwt_claims_rem=$((${#_jwt_claims_payload} % 4))
  case "$_jwt_claims_rem" in
  2) _jwt_claims_payload="${_jwt_claims_payload}==" ;;
  3) _jwt_claims_payload="${_jwt_claims_payload}=" ;;
  1) die "malformed access token" ;;
  esac
  printf '%s' "$_jwt_claims_payload" | openssl base64 -d -A 2>/dev/null
}

# require_app_permissions PERM...: die unless every PERM is in the current
# token's `permissions` claim.
require_app_permissions() {
  _require_app_permissions_perm=""
  _require_app_permissions_claims="$(jwt_claims "$TOKEN")"
  [ -n "$_require_app_permissions_claims" ] || die "could not decode the access token"
  for _require_app_permissions_perm in "$@"; do
    printf '%s' "$_require_app_permissions_claims" | jq -e --arg p "$_require_app_permissions_perm" \
      '(.permissions // []) | index($p) != null' >/dev/null ||
      die "the '$USERNAME' account lacks the '$_require_app_permissions_perm' permission this command needs"
  done
}

# read_password PROMPT -> the entered value, terminal echo suppressed.
read_password() {
  printf '%s' "$1" >&2
  stty -echo 2>/dev/null
  trap 'stty echo 2>/dev/null' EXIT INT TERM
  read -r _read_password_pass
  stty echo 2>/dev/null
  trap - EXIT INT TERM
  echo >&2
  printf '%s' "$_read_password_pass"
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
  _login_body="$(jq -n --arg u "$USERNAME" --arg p "$PASSWORD" '{username:$u,password:$p}')"
  TOKEN="$(check_response "$(api_login "$_login_body")" "login" | jq -r '.access_token')"
  [ -n "$TOKEN" ] && [ "$TOKEN" != null ] ||
    die "login succeeded but the response had no access_token"
}

# --- orphans / gc --------------------------------------------------------------

# -> every referenced checksum, space-joined (in_list's expected form).
build_db_checksum_set() {
  _build_db_checksum_set_checksums="$(media_list checksum | jq -r '.[].checksum')"
  # shellcheck disable=SC2086,SC2116 # unquoted echo collapses newlines to spaces
  echo $_build_db_checksum_set_checksums
}

# list_orphans DB_SET -> "key<TAB>size" lines for S3 objects not in DB_SET.
list_orphans() {
  _list_orphans_db_set="$1"
  _list_orphans_kv="$(aws --region "$REGION" s3api list-objects-v2 --bucket "$BUCKET" \
    --query 'Contents[].[Key,Size]' --output text)"
  [ "$_list_orphans_kv" != "None" ] || return 0
  printf '%s\n' "$_list_orphans_kv" | while IFS="$TAB" read -r key size; do
    [ -n "$key" ] || continue
    in_list "$key" "$_list_orphans_db_set" || printf '%s\t%s\n' "$key" "$size"
  done
}

cmd_orphans() {
  _cmd_orphans_orphans="$(list_orphans "$(build_db_checksum_set)")"
  if [ -z "$_cmd_orphans_orphans" ]; then
    log "no orphaned objects."
    return 0
  fi
  printf '%s\n' "$_cmd_orphans_orphans" | while IFS="$TAB" read -r key size; do
    [ -n "$key" ] || continue
    log "ORPHAN $key  ($size bytes)"
  done
  _cmd_orphans_count="$(printf '%s\n' "$_cmd_orphans_orphans" | grep -c .)"
  _cmd_orphans_total="$(printf '%s\n' "$_cmd_orphans_orphans" | awk -F"$TAB" '{s+=$2} END{print s+0}')"
  log "$_cmd_orphans_count orphaned object(s), $_cmd_orphans_total bytes total. Re-run with 'gc' to delete them."
}

cmd_gc() {
  _cmd_gc_orphans="$(list_orphans "$(build_db_checksum_set)")"
  if [ -z "$_cmd_gc_orphans" ]; then
    log "no orphaned objects; nothing to delete."
    return 0
  fi
  printf '%s\n' "$_cmd_gc_orphans" | while IFS="$TAB" read -r key size; do
    [ -n "$key" ] || continue
    log "DELETE $key  ($size bytes)"
  done
  confirm "Delete the objects marked DELETE above from s3://$BUCKET? (versioning + expire-noncurrent give a 90-day undo window)"
  printf '%s\n' "$_cmd_gc_orphans" | while IFS="$TAB" read -r key size; do
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
  _plan_renames_handle="" _plan_renames_checksum="" _plan_renames_path="" _plan_renames_new_path=""
  printf '%s\n' "$1" | while IFS="$TAB" read -r _plan_renames_handle _plan_renames_checksum _plan_renames_path; do
    [ -n "$_plan_renames_handle" ] || continue
    _plan_renames_new_path="$(canonical_path "$_plan_renames_checksum" "$_plan_renames_path")"
    [ "$_plan_renames_path" != "$_plan_renames_new_path" ] || continue
    log "RENAME $_plan_renames_path -> $_plan_renames_new_path  (handle $_plan_renames_handle)"
    printf '%s\t%s\n' "$_plan_renames_handle" "$_plan_renames_new_path"
  done
}

# rewrite_path HANDLE NEW_PATH: read-modify-write, since PUT /media/<handle>
# replaces the whole object (resources/base.py). Only `path` changes; every
# other field round-trips as the API returned it.
rewrite_path() {
  _rewrite_path_obj="$(check_response "$(api_call GET "/media/$1")" "GET /media/$1")"
  _rewrite_path_new_obj="$(printf '%s' "$_rewrite_path_obj" | jq --arg p "$2" '.path = $p')"
  check_response "$(api_call PUT "/media/$1" "$_rewrite_path_new_obj")" "PUT /media/$1" >/dev/null
}

cmd_flatten() {
  _cmd_flatten_apply="$1"
  _cmd_flatten_rows="$(media_list "handle,checksum,path" | jq -r '.[] | [.handle,.checksum,.path] | @tsv')"
  _cmd_flatten_renames="$(plan_renames "$_cmd_flatten_rows")"
  if [ -z "$_cmd_flatten_renames" ]; then
    log "no legacy paths; nothing to flatten."
    return 0
  fi
  _cmd_flatten_count="$(printf '%s\n' "$_cmd_flatten_renames" | grep -c .)"
  if [ "$_cmd_flatten_apply" != 1 ]; then
    log "$_cmd_flatten_count path(s) would be rewritten. Re-run with 'flatten --apply' to apply."
    return 0
  fi
  confirm "Rewrite the $_cmd_flatten_count path(s) listed above?"
  printf '%s\n' "$_cmd_flatten_renames" | while IFS="$TAB" read -r handle new_path; do
    [ -n "$handle" ] || continue
    log "rewriting $handle -> $new_path..."
    rewrite_path "$handle" "$new_path"
  done
  log "done."
}

main() {
  select_root "$@"
  shift "$ROOT_SHIFT"
  _main_cmd="${1:-}"
  _main_apply_flag=0
  case "$_main_cmd" in
  orphans | gc)
    [ "$#" -eq 1 ] || usage
    ;;
  flatten)
    case "${2:-}" in
    '') ;;
    --apply) _main_apply_flag=1 ;;
    *) usage ;;
    esac
    [ "$#" -le 2 ] || usage
    ;;
  *) usage ;;
  esac

  require aws terraform jq curl openssl
  init_root
  readonly REGION
  BUCKET="$(tf_output media_bucket_name)"
  readonly BUCKET
  DOMAIN="$(tf_output primary_domain)"
  readonly DOMAIN
  API="https://$DOMAIN/api"
  readonly API

  get_credentials
  login

  case "$_main_cmd" in
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
    cmd_flatten "$_main_apply_flag"
    ;;
  esac
}

main "$@"
