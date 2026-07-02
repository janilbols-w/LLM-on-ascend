#!/usr/bin/env bash
set -euo pipefail

# Goal:
# Run two test cases in alternating order for two rounds: A -> B -> A -> B.
# This is useful to compare cache-hit behavior across environments.

API_URL="${API_URL:-http://192.168.0.4:7000/v1/chat/completions}"
MODEL="${MODEL:-glm-52}"
OUT_DIR="${OUT_DIR:-./multi_turn_outputs}"
TARGET_KV_TOKENS="${TARGET_KV_TOKENS:-512000}"
MAX_PROMPT_TOKENS_PER_CASE="${MAX_PROMPT_TOKENS_PER_CASE:-180000}"
MAX_TOKENS="${MAX_TOKENS:-32}"
ROUNDS="${ROUNDS:-2}"
CALIB_REPEAT="${CALIB_REPEAT:-600}"

mkdir -p "$OUT_DIR"

extract_prompt_tokens() {
  local f="$1"
  grep -o '"prompt_tokens":[0-9]\+' "$f" | head -n1 | cut -d: -f2
}

# Case A and B are intentionally different so each case has its own cache key.
make_prompt() {
  local case_name="$1"
  local repeats="$2"
  awk -v n="$repeats" -v cn="$case_name" 'BEGIN {
    if (cn == "caseA") {
      base = "[CaseA] This is a long context block for KV cache stress testing. Keep all details in memory. "
    } else {
      base = "[CaseB] This is another long context block for KV cache stress testing. Keep all details in memory. "
    }
    for (i = 0; i < n; i++) {
      printf "%s", base
    }
  }'
}

send_request() {
  local case_name="$1"
  local repeats="$2"
  local out_file="$3"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    # Fake response for dry-run flow validation.
    local fake_tokens=$(( repeats * 8 ))
    cat > "$out_file" <<JSON
{"id":"dry_run","usage":{"prompt_tokens":$fake_tokens,"completion_tokens":$MAX_TOKENS,"total_tokens":$((fake_tokens + MAX_TOKENS))}}
JSON
    return 0
  fi

  local prompt payload_file
  prompt="$(make_prompt "$case_name" "$repeats")"
  payload_file="${out_file%.json}.payload.json"

  cat > "$payload_file" <<JSON
{
  "model": "$MODEL",
  "messages": [
    {
      "role": "user",
      "content": "$prompt"
    }
  ],
  "max_tokens": $MAX_TOKENS,
  "stream": false,
  "temperature": 0
}
JSON

  time curl -sS "$API_URL" \
    -H "Content-Type: application/json" \
    --data-binary "@$payload_file" \
    -o "$out_file"
}

calibrate_case() {
  local case_name="$1"
  local calib_out="$OUT_DIR/${case_name}_calib.json"

  send_request "$case_name" "$CALIB_REPEAT" "$calib_out"

  local calib_tokens
  calib_tokens="$(extract_prompt_tokens "$calib_out" || true)"
  if [[ -z "$calib_tokens" ]]; then
    echo "[ERROR] Failed to parse prompt_tokens from calibration output: $calib_out"
    echo "Response preview:" && head -c 400 "$calib_out" && echo
    exit 1
  fi

  local tpr=$(( calib_tokens / CALIB_REPEAT ))
  if (( tpr < 1 )); then
    tpr=1
  fi
  echo "$tpr"
}

if (( ROUNDS < 1 )); then
  echo "[ERROR] ROUNDS must be >= 1"
  exit 1
fi
if (( CALIB_REPEAT < 1 )); then
  echo "[ERROR] CALIB_REPEAT must be >= 1"
  exit 1
fi

# Split target budget by two cases (A and B).
target_per_case=$(( TARGET_KV_TOKENS / 2 ))
if (( target_per_case > MAX_PROMPT_TOKENS_PER_CASE )); then
  target_per_case="$MAX_PROMPT_TOKENS_PER_CASE"
fi

echo "[INFO] Calibrating token density for caseA and caseB..."
tpr_a="$(calibrate_case caseA)"
tpr_b="$(calibrate_case caseB)"

repeats_a=$(( target_per_case / tpr_a ))
repeats_b=$(( target_per_case / tpr_b ))
if (( repeats_a < 1 )); then repeats_a=1; fi
if (( repeats_b < 1 )); then repeats_b=1; fi

echo "[INFO] TARGET_KV_TOKENS=$TARGET_KV_TOKENS, target_per_case=$target_per_case"
echo "[INFO] caseA tokens/repeat=$tpr_a, repeats=$repeats_a"
echo "[INFO] caseB tokens/repeat=$tpr_b, repeats=$repeats_b"
echo "[INFO] Sequence pattern: A -> B, repeated $ROUNDS round(s)"

summary_file="$OUT_DIR/summary.tsv"
echo -e "step\tcase\tround\tprompt_tokens\toutput" > "$summary_file"

step=0
for round in $(seq 1 "$ROUNDS"); do
  step=$((step + 1))
  out_a="$OUT_DIR/caseA_r${round}.json"
  echo "[INFO] Step $step: run caseA round $round"
  send_request "caseA" "$repeats_a" "$out_a"
  p_a="$(extract_prompt_tokens "$out_a" || true)"
  if [[ -z "$p_a" ]]; then p_a=0; fi
  echo -e "${step}\tcaseA\t${round}\t${p_a}\t${out_a}" >> "$summary_file"

  step=$((step + 1))
  out_b="$OUT_DIR/caseB_r${round}.json"
  echo "[INFO] Step $step: run caseB round $round"
  send_request "caseB" "$repeats_b" "$out_b"
  p_b="$(extract_prompt_tokens "$out_b" || true)"
  if [[ -z "$p_b" ]]; then p_b=0; fi
  echo -e "${step}\tcaseB\t${round}\tprompt_tokens\t${p_b}\t${out_b}" | sed 's/\tprompt_tokens\t/\t/' >> "$summary_file"
done

echo "[RESULT] Completed sequence A->B->A->B (for ROUNDS=2)."
echo "[RESULT] Summary file: $summary_file"
cat "$summary_file"

echo "[HINT] To compare cache-hit behavior across environments, check server logs for:"
echo "       - LMCache hit tokens"
echo "       - Prefix cache hit rate"
echo "[HINT] For this script, compare caseA round1 vs round2 and caseB round1 vs round2."
