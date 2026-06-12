#!/usr/bin/env bash
set -o pipefail

# Internal custom benchmark runner for PD smoke tests.
# Usage:
#   run_perf_test-custom.sh <MODEL_PATH> <PORT> <TP>

MODEL_PATH=${1:?missing MODEL_PATH}
PORT=${2:?missing PORT}
TP=${3:?missing TP}

BENCH_MODEL_ID=${BENCH_MODEL_ID:-${SERVED_MODEL_ID:-$MODEL_PATH}}
ENDPOINT=${ENDPOINT:-/v1/completions}

INPUT_LENS=${INPUT_LENS:-"1024"}
OUTPUT_LEN=${OUTPUT_LEN:-64}
CONCURRENCIES=${CONCURRENCIES:-"1"}
NUM_PROMPTS_MULT=${NUM_PROMPTS_MULT:-4}
REQUEST_RATE=${REQUEST_RATE:-""}
PERCENTILES=${PERCENTILES:-"95,99"}
IMAGE_NAME=${IMAGE_NAME:-unknown}
GPU_RANGE=${GPU_RANGE:-"0,1,2,3,4,5,6,7"}
TEST_MODE=${TEST_MODE:-custom}

model=${MODEL_NAME:-${BENCH_MODEL_ID##*/}}
date_tag=$(date "+%Y%m%d")
time_tag=$(date "+%H%M%S")

if [[ -n "${WORK_DIR:-}" ]]; then
    RUN_DIR="${WORK_DIR}"
    LOG_DIR="${WORK_DIR}/logs"
    CSV_DIR="${WORK_DIR}/csvs/${TEST_MODE}"
else
    image_tag=${IMAGE_NAME: -12}
    OUTPUT_BASE="/mnt/skilltest/vllm-perf-validation-pd/csvs/${model}"
    RUN_DIR="${OUTPUT_BASE}/${date_tag}-${time_tag}-${image_tag}-${TEST_MODE}"
    LOG_DIR="${RUN_DIR}/logs"
    CSV_DIR="${RUN_DIR}"
fi

mkdir -p "$LOG_DIR" "$CSV_DIR"
all_log="${CSV_DIR}/all.csv"

{
    echo "# started_at: $(date "+%Y-%m-%d %H:%M:%S")"
    echo "# model_path: ${MODEL_PATH}"
    echo "# served_model_id: ${SERVED_MODEL_ID:-unset}"
    echo "# bench_model_id: ${BENCH_MODEL_ID}"
    echo "# endpoint: ${ENDPOINT}"
    echo "# image_name: ${IMAGE_NAME}"
    echo "# gpu_range: ${GPU_RANGE}"
    echo "# tp: ${TP}"
    echo "# test_mode: ${TEST_MODE}"
    echo "# work_dir: ${RUN_DIR}"
    echo "# input_lens: ${INPUT_LENS}"
    echo "# output_len: ${OUTPUT_LEN}"
    echo "# concurrencies: ${CONCURRENCIES}"
    echo "# num_prompts_mult: ${NUM_PROMPTS_MULT}"
    echo "# request_rate: ${REQUEST_RATE:-unset}"
    echo "# percentiles: ${PERCENTILES}"
    echo ""
    echo "vllm bench serve \\"
    echo "  --model ${BENCH_MODEL_ID} \\"
    echo "  --port ${PORT} \\"
    echo "  --endpoint ${ENDPOINT} \\"
    echo "  --dataset-name random \\"
    echo "  --random-input-len <INPUT_LEN> \\"
    echo "  --random-output-len ${OUTPUT_LEN} \\"
    echo "  --num-prompts <NUM_PROMPTS> \\"
    echo "  --max-concurrency <CONCURRENCY> \\"
    if [[ -n "$REQUEST_RATE" ]]; then
        echo "  --request-rate ${REQUEST_RATE} \\"
    fi
    echo "  --metric-percentiles ${PERCENTILES} \\"
    echo "  --ignore-eos \\"
    echo "  --trust-remote-code"
} > "${RUN_DIR}/commands_backup.txt"

echo "input,output,num_prompts,concurrency,request_rate,duration_s,rps,generate_throughput_tok_s,total_throughput_tok_s,mean_ttft,p50_ttft,p90_ttft,p99_ttft,mean_tpot,p50_tpot,p90_tpot,p99_tpot,mean_itl,p50_itl,p90_itl,p99_itl,status,error_reason" > "$all_log"

echo "CUSTOM_BENCH_START=1"
echo "MODEL_PATH=${MODEL_PATH}"
echo "BENCH_MODEL_ID=${BENCH_MODEL_ID}"
echo "ENDPOINT=${ENDPOINT}"
echo "PORT=${PORT}"
echo "TP=${TP}"
echo "INPUT_LENS=${INPUT_LENS}"
echo "OUTPUT_LEN=${OUTPUT_LEN}"
echo "CONCURRENCIES=${CONCURRENCIES}"
echo "NUM_PROMPTS_MULT=${NUM_PROMPTS_MULT}"
echo "PERCENTILES=${PERCENTILES}"
echo "REQUEST_RATE=${REQUEST_RATE:-unset}"
echo "RUN_DIR=${RUN_DIR}"

overall_rc=0
exec_summary=""

metric_value() {
    local pattern=$1
    local field=$2
    local file=$3
    grep -a "$pattern" "$file" | tail -n 1 | awk -v f="$field" '{print $f}'
}

for input_len in $INPUT_LENS; do
    for concurrency in $CONCURRENCIES; do
        num_prompts=$((concurrency * NUM_PROMPTS_MULT))
        log_file="${LOG_DIR}/${model}-in${input_len}-out${OUTPUT_LEN}-c${concurrency}-n${num_prompts}.log"
        watchdog_result="${log_file}.watchdog.json"

        echo "BENCH_CASE_START input=${input_len} output=${OUTPUT_LEN} concurrency=${concurrency} num_prompts=${num_prompts}"

        cmd=(
            vllm bench serve
            --model "$BENCH_MODEL_ID"
            --port "$PORT"
            --endpoint "$ENDPOINT"
            --dataset-name random
            --random-input-len "$input_len"
            --random-output-len "$OUTPUT_LEN"
            --num-prompts "$num_prompts"
            --max-concurrency "$concurrency"
            --metric-percentiles "$PERCENTILES"
            --ignore-eos
            --trust-remote-code
        )

        if [[ -n "$REQUEST_RATE" ]]; then
            cmd+=(--request-rate "$REQUEST_RATE")
        fi

        python3 scripts/ops/bench_watchdog.py \
            --state "${STATE:?missing STATE}" \
            --log-file "$log_file" \
            --result-file "$watchdog_result" \
            --prefill-log "${PREFILL_LOG:?missing PREFILL_LOG}" \
            --decode-log "${DECODE_LOG:?missing DECODE_LOG}" \
            --timeout "${BENCH_TIMEOUT:-3600}" \
            --heartbeat-interval 30 \
            --input-len "$input_len" \
            --output-len "$OUTPUT_LEN" \
            --concurrency "$concurrency" \
            --num-prompts "$num_prompts" \
            -- "${cmd[@]}"
        bench_rc=$?
        watchdog_reason=$(python3 - "$watchdog_result" <<'PY'
import json
import sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("reason") or "")
except Exception:
    print("")
PY
)

        Benchmark_duration=$(metric_value "^Benchmark duration" 4 "$log_file")
        request_rate=$(metric_value "^Traffic request rate" 4 "$log_file")
        qps=$(metric_value "^Request throughput" 4 "$log_file")
        Output_token_throughput=$(metric_value "^Output token throughput" 5 "$log_file")
        Total_Token_throughput=$(grep -ai "^Total token throughput" "$log_file" | tail -n 1 | awk '{print $5}')
        successful=$(metric_value "^Successful requests" 4 "$log_file")
        failed=$(metric_value "^Failed requests" 4 "$log_file")

        Mean_TTFT=$(metric_value "^Mean TTFT" 4 "$log_file")
        P50_TTFT=$(metric_value "^P50 TTFT" 4 "$log_file")
        P90_TTFT=$(metric_value "^P90 TTFT" 4 "$log_file")
        P99_TTFT=$(metric_value "^P99 TTFT" 4 "$log_file")

        Mean_TPOT=$(metric_value "^Mean TPOT" 4 "$log_file")
        P50_TPOT=$(metric_value "^P50 TPOT" 4 "$log_file")
        P90_TPOT=$(metric_value "^P90 TPOT" 4 "$log_file")
        P99_TPOT=$(metric_value "^P99 TPOT" 4 "$log_file")

        Mean_ITL=$(metric_value "^Mean ITL" 4 "$log_file")
        P50_ITL=$(metric_value "^P50 ITL" 4 "$log_file")
        P90_ITL=$(metric_value "^P90 ITL" 4 "$log_file")
        P99_ITL=$(metric_value "^P99 ITL" 4 "$log_file")

        if [[ "$bench_rc" != "0" ]]; then
            status="FAIL"
            error_reason="${watchdog_reason:-bench_exit_nonzero}"
            overall_rc=1
        elif [[ -n "$successful" && "$successful" == "0" && -n "$failed" && "$failed" != "0" ]]; then
            status="FAIL"
            error_reason="all_requests_failed_${failed}"
            overall_rc=1
        elif [[ -n "$failed" && "$failed" != "0" ]]; then
            status="PARTIAL"
            error_reason="failed_requests_${failed}"
            overall_rc=1
        elif [[ -n "$qps" && "$qps" != "0" ]]; then
            status="PASS"
            error_reason=""
        else
            status="FAIL"
            error_reason="invalid_metrics"
            overall_rc=1
        fi

        echo "${input_len},${OUTPUT_LEN},${num_prompts},${concurrency},${request_rate:-},${Benchmark_duration:-},${qps:-},${Output_token_throughput:-},${Total_Token_throughput:-},${Mean_TTFT:-},${P50_TTFT:-},${P90_TTFT:-},${P99_TTFT:-},${Mean_TPOT:-},${P50_TPOT:-},${P90_TPOT:-},${P99_TPOT:-},${Mean_ITL:-},${P50_ITL:-},${P90_ITL:-},${P99_ITL:-},${status},${error_reason}" >> "$all_log"

        exec_summary="${exec_summary}
#   input=${input_len} output=${OUTPUT_LEN} concurrency=${concurrency} num_prompts=${num_prompts} status=${status}"

        echo "BENCH_CASE_DONE status=${status} error_reason=${error_reason:-none}"
    done
done

{
    echo ""
    echo "# executed_cases:"
    echo "$exec_summary"
} >> "${RUN_DIR}/commands_backup.txt"

echo "CUSTOM_BENCH_DONE=$((overall_rc == 0 ? 1 : 0))"
echo "CUSTOM_BENCH_RC=${overall_rc}"
echo "CSV_FILE=${all_log}"
cat "$all_log"

exit "$overall_rc"
