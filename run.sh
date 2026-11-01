#!/usr/bin/env bash
# Sitetools GitHub Action: start a run, wait for it, summarise it, gate the job.
# Plain bash + curl + jq so it works on every GitHub-hosted runner with no build.
set -euo pipefail

: "${INPUT_API_KEY:?api-key is required}"
: "${INPUT_SITE_ID:?site-id is required}"
APP_URL="${INPUT_APP_URL:-https://app.sitetools.pro}"
APP_URL="${APP_URL%/}"
FAIL_ON="${INPUT_FAIL_ON:-error}"
TIMEOUT="${INPUT_TIMEOUT_SECONDS:-600}"
LABEL="${INPUT_LABEL:-${GITHUB_SHA:-}}"
API="$APP_URL/api/v1/sites/$INPUT_SITE_ID"
AUTH=(-H "Authorization: Bearer $INPUT_API_KEY")
GITHUB_OUTPUT="${GITHUB_OUTPUT:-/dev/null}"
GITHUB_STEP_SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

log() { printf '%s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { log "::error::$1 is required on the runner"; exit 1; }; }
need curl; need jq

# ---- build the request --------------------------------------------------------
FORM=(-F "label=$LABEL")
[ -n "${INPUT_PACK:-}" ] && FORM+=(-F "suite=$INPUT_PACK")
TMP_ZIP=""
cleanup() { [ -n "$TMP_ZIP" ] && rm -f "$TMP_ZIP"; }
trap cleanup EXIT

if [ -n "${INPUT_BUILD_DIR:-}" ]; then
  [ -d "$INPUT_BUILD_DIR" ] || { log "::error::build-dir '$INPUT_BUILD_DIR' does not exist"; exit 1; }
  need zip
  TMP_ZIP="$(mktemp -t sitetools-build.XXXXXX).zip"
  (cd "$INPUT_BUILD_DIR" && zip -qr "$TMP_ZIP" .)
  FORM+=(-F "archive=@$TMP_ZIP;filename=build.zip")
  log "Sending build from $INPUT_BUILD_DIR ($(du -h "$TMP_ZIP" | cut -f1))"
fi
if [ -n "${INPUT_URLS:-}" ]; then
  FORM+=(-F "urls=$INPUT_URLS")
fi
if [ -n "${INPUT_SITEMAP:-}" ]; then
  FORM+=(-F "sitemap=$INPUT_SITEMAP")
fi
if [ -z "${INPUT_BUILD_DIR:-}" ] && [ -z "${INPUT_URLS:-}" ] && [ -z "${INPUT_SITEMAP:-}" ]; then
  log "::error::Give the action a build-dir, urls or sitemap to check"
  exit 1
fi

# ---- start the run ------------------------------------------------------------
START="$(curl -sS -w '\n%{http_code}' -X POST "$API/runs" "${AUTH[@]}" "${FORM[@]}")"
START_CODE="${START##*$'\n'}"
START_BODY="${START%$'\n'*}"
if [ "$START_CODE" -ge 300 ]; then
  MSG="$(printf '%s' "$START_BODY" | jq -r '.statusMessage // .message // .' 2>/dev/null || printf '%s' "$START_BODY")"
  log "::error::Sitetools refused the run (HTTP $START_CODE): $MSG"
  exit 1
fi
# The API wraps documents as { doc } (sometimes { doc: { doc } }); unwrap once.
unwrap() { jq -c '(.doc.doc // .doc // .)'; }
START_DOC="$(printf '%s' "$START_BODY" | unwrap)"
RUN_ID="$(printf '%s' "$START_DOC" | jq -r '._id // .id // empty')"
[ -n "$RUN_ID" ] || { log "::error::Could not read the run id from the response"; log "$START_BODY"; exit 1; }
REPORT_URL="$APP_URL/sites/$INPUT_SITE_ID/runs/$RUN_ID"
NOTICE="$(printf '%s' "$START_DOC" | jq -r '.notice // empty')"
log "Run $RUN_ID started → $REPORT_URL"
[ -n "$NOTICE" ] && log "$NOTICE"
echo "run-id=$RUN_ID" >> "$GITHUB_OUTPUT"
echo "report-url=$REPORT_URL" >> "$GITHUB_OUTPUT"

# ---- wait ---------------------------------------------------------------------
DEADLINE=$(( $(date +%s) + TIMEOUT ))
SLEEP=3
while :; do
  REPORT="$(curl -sS "$API/runs/$RUN_ID" "${AUTH[@]}" | unwrap)"
  STATUS="$(printf '%s' "$REPORT" | jq -r '.run.status // empty')"
  case "$STATUS" in
    completed|failed) break ;;
  esac
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    log "::error::Timed out after ${TIMEOUT}s waiting for run $RUN_ID (status: ${STATUS:-unknown}). $REPORT_URL"
    echo "status=timeout" >> "$GITHUB_OUTPUT"
    exit 1
  fi
  sleep "$SLEEP"
  [ "$SLEEP" -lt 10 ] && SLEEP=$(( SLEEP + 1 ))
done

# ---- summarise ----------------------------------------------------------------
SUMMARY="$(printf '%s' "$REPORT" | jq -c '.run.summary // {}')"
ERROR_MSG="$(printf '%s' "$REPORT" | jq -r '.run.error // empty')"
SCORE="$(printf '%s' "$SUMMARY" | jq -r '.score // 0')"
PASSED="$(printf '%s' "$SUMMARY" | jq -r '.passed // 0')"
FAILED="$(printf '%s' "$SUMMARY" | jq -r '.failed // 0')"
WARNINGS="$(printf '%s' "$SUMMARY" | jq -r '.warnings // 0')"
PAGES="$(printf '%s' "$SUMMARY" | jq -r '.pages // 0')"
{
  echo "status=$STATUS"
  echo "score=$SCORE"
  echo "passed=$PASSED"
  echo "failed=$FAILED"
  echo "warnings=$WARNINGS"
} >> "$GITHUB_OUTPUT"

if [ "$STATUS" = "failed" ]; then
  log "::error::Run $RUN_ID failed: ${ERROR_MSG:-unknown error}. $REPORT_URL"
fi

# Markdown table of non-passing checks with their first finding.
TABLE="$(printf '%s' "$REPORT" | jq -r '
  [.results[]? | select(.status == "failed" or .status == "warning")]
  | sort_by(.status != "failed", .name)
  | .[:50]
  | map("| " + (if .status == "failed" then "❌" else "⚠️" end)
        + " | " + (.name | gsub("\\|"; "\\|"))
        + " | " + ((.findingCount // 0) | tostring)
        + " | " + (((.findings[0].page // "") + (if (.findings[0].page // "") != "" then " — " else "" end) + (.findings[0].message // "")) | gsub("\n"; " ") | gsub("\\|"; "\\|") | .[:140])
        + " |")
  | join("\n")')"
VERDICT_ICON="✅"; VERDICT_TEXT="Clear to ship"
if [ "$STATUS" = "failed" ]; then VERDICT_ICON="💥"; VERDICT_TEXT="Run failed"
elif [ "$FAILED" -gt 0 ]; then VERDICT_ICON="❌"; VERDICT_TEXT="$FAILED check$([ "$FAILED" = 1 ] || echo s) failed"
elif [ "$WARNINGS" -gt 0 ]; then VERDICT_ICON="⚠️"; VERDICT_TEXT="$WARNINGS warning$([ "$WARNINGS" = 1 ] || echo s)"
fi
MD="$(cat <<MD
### $VERDICT_ICON Sitetools: $VERDICT_TEXT

**Score $SCORE / 100** · $PASSED passed · $FAILED failed · $WARNINGS warnings · $PAGES page$([ "$PAGES" = 1 ] || echo s) · [Open the report]($REPORT_URL)
$( [ -n "$ERROR_MSG" ] && printf '\n> %s\n' "$ERROR_MSG" )
$( if [ -n "$TABLE" ]; then printf '\n| | Check | Findings | First finding |\n|---|---|---:|---|\n%s\n' "$TABLE"; fi )
MD
)"
printf '%s\n' "$MD" >> "$GITHUB_STEP_SUMMARY"
log ""
log "$VERDICT_ICON $VERDICT_TEXT · score $SCORE · $PASSED passed · $FAILED failed · $WARNINGS warnings"
log "$REPORT_URL"

# ---- sticky pull request comment ----------------------------------------------
if [ "${INPUT_COMMENT:-true}" = "true" ] && [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] && [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  PR_NUMBER="$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH:-/dev/null}" 2>/dev/null || true)"
  if [ -n "$PR_NUMBER" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    MARKER="<!-- sitetools-checks:$INPUT_SITE_ID -->"
    BODY="$(printf '%s\n%s' "$MARKER" "$MD")"
    EXISTING="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" --paginate -q ".[] | select(.body | startswith(\"$MARKER\")) | .id" 2>/dev/null | head -n1 || true)"
    if [ -n "$EXISTING" ]; then
      gh api -X PATCH "repos/$GITHUB_REPOSITORY/issues/comments/$EXISTING" -f body="$BODY" >/dev/null && log "Updated the pull request comment"
    else
      gh api -X POST "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" -f body="$BODY" >/dev/null && log "Posted a pull request comment"
    fi
  fi
fi

# ---- gate ---------------------------------------------------------------------
case "$FAIL_ON" in
  none) exit 0 ;;
  warning)
    if [ "$STATUS" = "failed" ] || [ "$FAILED" -gt 0 ] || [ "$WARNINGS" -gt 0 ]; then
      log "::error::Failing the job: fail-on=warning and the run has $FAILED failed, $WARNINGS warnings"
      exit 1
    fi ;;
  *)
    if [ "$STATUS" = "failed" ] || [ "$FAILED" -gt 0 ]; then
      log "::error::Failing the job: $FAILED check$([ "$FAILED" = 1 ] || echo s) failed"
      exit 1
    fi ;;
esac

exit 0
