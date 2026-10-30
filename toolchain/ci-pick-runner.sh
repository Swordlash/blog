#!/bin/sh
# Which runner this run's wasm job takes: the owner's machine
# (`self-hosted`) when the run is trusted and the machine is free, GitHub's
# hosted runners (`ubuntu-latest`) otherwise. Prints `runner=<label>` for
# $GITHUB_OUTPUT, and the decision with its reason, in one line, to the
# log (stderr) and to the run's summary ($GITHUB_STEP_SUMMARY, when set).
#
# GitHub has no "first available" across a self-hosted runner and its
# hosted ones: `runs-on` with several labels asks for a runner carrying all
# of them. So the workflow's first job, `plan`, which always runs on a
# hosted runner, asks this script and hands its answer only to wasm's
# `runs-on`. The other jobs always use hosted runners.
#
# Usage: ci-pick-runner.sh, with
#   TRUSTED          `true` when the workflow's trust rule lets the run use
#                    the owner's machine (see the top of build.yml, where
#                    the rule is written); anything else is untrusted.
#   RUNNER_INPUT     the dispatch input `runner`, empty for other events:
#                    `hosted` asks for the hosted runners, whatever else.
#   GITHUB_REPOSITORY, GITHUB_RUN_ID, GH_TOKEN (a token that may read the
#                    repository's Actions runs), GITHUB_API_URL (optional).
#
# The rule: a run by hand that asks for `hosted`, and a run that is not
# trusted, take the hosted runners, without asking the API. A trusted run
# takes the owner's machine unless it is busy: another run of this workflow
# (not this one, whatever its attempt), queued or in progress, has a job
# that asked for `self-hosted` (its `labels`, which are the `runs-on` it
# asked for, set before it is given a runner) and is queued or in progress.
# A job `waiting` on an environment's approval, and a finished one, do not
# count. Another run, queued or in progress, that lists no jobs at all
# counts as busy: where its jobs will run cannot be known yet, and the
# hosted runners, always there, are the side that cannot wait on a busy
# machine. Any doubt (an API error, a response it cannot read, a missing
# tool) answers `ubuntu-latest`, which is always there, and says why.
#
# The newest 30 queued and the newest 30 running runs are looked at, which
# is far more than one machine's queue ever holds. What the token cannot
# see is whether the self-hosted runner is online (that needs
# `administration: read`, which a workflow's token cannot have): a run
# sent to a machine that is off waits in its queue until the machine is
# back, or until it is cancelled and run by hand with `runner: hosted`.
set -eu

workflow=${WORKFLOW_FILE:-build.yml}
api=${GITHUB_API_URL:-https://api.github.com}

# The answer, printed for $GITHUB_OUTPUT, with its reason for the log and
# the summary, and the end of the script. Called only from the script's own
# shell, never from a command substitution, so the exit ends the script.
pick() {
  printf 'runner=%s\n' "$1"
  line="Runner: $1, because $2."
  printf '%s\n' "$line" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s\n' "$line" >>"$GITHUB_STEP_SUMMARY" || true
  fi
  exit 0
}

hosted() {
  pick ubuntu-latest "$1"
}

if [ "${RUNNER_INPUT:-}" = hosted ]; then
  hosted "the run by hand asked for the hosted runners (the input runner: hosted)"
fi
if [ "${TRUSTED:-}" != true ]; then
  hosted "the run is not trusted (a fork's pull request, or a bot's), so it does not run on the owner's machine"
fi
for tool in curl awk; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    hosted "there is no $tool here to ask the Actions API whether the owner's machine is busy"
  fi
done
if [ -z "${GITHUB_REPOSITORY:-}" ] || [ -z "${GITHUB_RUN_ID:-}" ] || [ -z "${GH_TOKEN:-}" ]; then
  hosted "GITHUB_REPOSITORY, GITHUB_RUN_ID or GH_TOKEN is not set, so the Actions API cannot be asked whether the owner's machine is busy"
fi

# A GET of the API into $response, failing on an error (curl -f, so an
# HTTP error status fails too). Its stdin is closed: the loops below read
# the rows they go through from theirs.
get() {
  response=$(curl -fsS \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "$api/repos/$GITHUB_REPOSITORY/$1" </dev/null)
}

# Reads one JSON document and prints a line for each object of the array
# that the top-level object holds under the key `name`: the object's own
# `id`, `status`, `labels` (space-separated) and `name`, tab-separated,
# `-` for a field it does not have; then `end`. A document it cannot read
# (unbalanced, an unterminated string, no such array) prints no `end`,
# which the caller takes as malformed. A real if small JSON reader rather
# than grep, because the fields that matter repeat inside nested objects:
# a run's actor and repository have ids of their own, and each step of a
# job has a status of its own, and the order of a job's fields is not
# something the API promises.
reader=$(
  cat <<'AWK'
function scalar(v) {
  if (depth == 3 && inelement) {
    if (key[3] == "id") id = v
    else if (key[3] == "status") status = v
    else if (key[3] == "name") title = v
  } else if (depth == 4 && inelement && kind[4] == "[" && key[3] == "labels") {
    labels = labels (labels == "" ? "" : " ") v
  }
}
function orDash(v) { return v == "" ? "-" : v }
{ doc = doc $0 "\n" }
END {
  n = length(doc); depth = 0; found = 0; ok = 1; expectkey = 0; inelement = 0
  for (i = 1; i <= n && ok; i++) {
    c = substr(doc, i, 1)
    if (c == "\"") {
      v = ""
      for (j = i + 1; ; ) {
        if (j > n) { ok = 0; break }
        d = substr(doc, j, 1)
        if (d == "\\") { v = v substr(doc, j, 2); j += 2 }
        else if (d == "\"") break
        else { v = v d; j++ }
      }
      i = j
      if (depth > 0 && kind[depth] == "{" && expectkey) { key[depth] = v; expectkey = 0 }
      else scalar(v)
    } else if (c == "{" || c == "[") {
      depth++; kind[depth] = c; key[depth] = ""; expectkey = (c == "{")
      if (depth == 1 && c != "{") ok = 0
      if (depth == 2 && c == "[" && key[1] == name) found = 1
      if (depth == 3 && c == "{" && kind[2] == "[" && key[1] == name) {
        inelement = 1; id = ""; status = ""; labels = ""; title = ""
      }
    } else if (c == "}" || c == "]") {
      if (depth == 0 || (c == "}" && kind[depth] != "{") || (c == "]" && kind[depth] != "[")) { ok = 0; break }
      if (depth == 3 && inelement) {
        printf "%s\t%s\t%s\t%s\n", orDash(id), orDash(status), orDash(labels), orDash(title)
        inelement = 0
      }
      depth--; expectkey = 0
    } else if (c == ":") {
      expectkey = 0
    } else if (c == ",") {
      if (depth > 0 && kind[depth] == "{") expectkey = 1
    } else if (c !~ /[ \t\r\n]/) {
      for (j = i; j <= n && substr(doc, j, 1) !~ /[],:{}[" \t\r\n]/; j++) ;
      scalar(substr(doc, i, j - i))
      i = j - 1
    }
  }
  if (ok && depth == 0 && found) print "end"
}
AWK
)

# The objects of the array named $1 in $response, into $rows, or the
# hosted runners when the response cannot be read; $2 says what it is.
read_rows() {
  rows=$(printf '%s' "$response" | awk -v name="$1" "$reader") || rows=
  case $rows in
  end | *"
end") rows=${rows%end} ;;
  *) hosted "the Actions API's answer for $2 could not be read: $(printf '%.200s' "$response" | tr -d '\n')" ;;
  esac
}

tab=$(printf '\t')
for run_status in queued in_progress; do
  if ! get "actions/workflows/$workflow/runs?status=$run_status&per_page=30"; then
    hosted "the Actions API did not list this workflow's runs that are $run_status"
  fi
  read_rows workflow_runs "the runs that are $run_status"
  runs=$rows
  while IFS=$tab read -r run_id _ _ _; do
    [ -n "$run_id" ] || continue
    case $run_id in
    *[!0-9]* | -) hosted "a run listed as $run_status has no id that can be read ($run_id)" ;;
    esac
    [ "$run_id" != "$GITHUB_RUN_ID" ] || continue
    if ! get "actions/runs/$run_id/jobs?per_page=100"; then
      hosted "the Actions API did not list the jobs of run $run_id, which is $run_status"
    fi
    read_rows jobs "the jobs of run $run_id"
    if [ -z "$rows" ]; then
      hosted "run $run_id is $run_status and lists no jobs yet, so it may yet take the owner's machine"
    fi
    while IFS=$tab read -r _ job_status labels job_name; do
      case $job_status in
      queued | in_progress) ;;
      *) continue ;;
      esac
      case " $labels " in
      *" self-hosted "*)
        hosted "the owner's machine is busy: job '$job_name' of run $run_id is $job_status there"
        ;;
      esac
    done <<EOF
$rows
EOF
  done <<EOF
$runs
EOF
done

pick self-hosted "the run is trusted and no other run has a job queued or in progress on the owner's machine"
