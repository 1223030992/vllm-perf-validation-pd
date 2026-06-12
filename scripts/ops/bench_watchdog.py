#!/usr/bin/env python3
"""Run one benchmark case with heartbeat, timeout, and Mooncake log monitoring."""

import argparse
import json
import os
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


PATTERNS = (
    ("mooncake_kv_pull_failed", ("Mooncake transfer engine returned -1", "pulling kv_caches")),
    ("mooncake_rdma_transfer_timeout", ("Sync batch data transfer timeout", "transport retry counter exceeded")),
)


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def set_path(data, dotted, value):
    current = data
    parts = dotted.split(".")
    for key in parts[:-1]:
        child = current.get(key)
        if not isinstance(child, dict):
            child = {}
            current[key] = child
        current = child
    current[parts[-1]] = value


def update_state(path, values):
    state = {}
    if path.exists():
        state = json.loads(path.read_text(encoding="utf-8-sig"))
    for key, value in values.items():
        set_path(state, key, value)
    state["updated_at"] = utc_now_iso()
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def classify_text(text):
    for reason, tokens in PATTERNS:
        if any(token in text for token in tokens):
            return reason
    return ""


def read_new(path, offset):
    try:
        with path.open("rb") as handle:
            handle.seek(offset)
            data = handle.read()
            return data.decode("utf-8", errors="replace"), handle.tell()
    except OSError:
        return "", offset


def stop_process(process):
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (AttributeError, OSError):
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (AttributeError, OSError):
            process.kill()


def write_result(path, reason, exit_code, elapsed, detail):
    path.write_text(
        json.dumps(
            {"reason": reason, "exit_code": exit_code, "elapsed_seconds": elapsed, "detail": detail[-4000:]},
            ensure_ascii=False,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--log-file", required=True, type=Path)
    parser.add_argument("--result-file", required=True, type=Path)
    parser.add_argument("--prefill-log", required=True, type=Path)
    parser.add_argument("--decode-log", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--heartbeat-interval", type=int, default=30)
    parser.add_argument("--input-len", required=True, type=int)
    parser.add_argument("--output-len", required=True, type=int)
    parser.add_argument("--concurrency", required=True, type=int)
    parser.add_argument("--num-prompts", required=True, type=int)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not command:
        raise SystemExit("missing benchmark command")

    args.log_file.parent.mkdir(parents=True, exist_ok=True)
    args.result_file.parent.mkdir(parents=True, exist_ok=True)
    case = {
        "input_len": args.input_len,
        "output_len": args.output_len,
        "concurrency": args.concurrency,
        "num_prompts": args.num_prompts,
    }
    start = time.monotonic()
    offsets = {}
    for path in (args.prefill_log, args.decode_log):
        try:
            offsets[path] = path.stat().st_size
        except OSError:
            offsets[path] = 0
    update_state(
        args.state,
        {
            "status": "BENCH_RUNNING",
            "test.status": "RUNNING",
            "test.current_case": case,
            "test.heartbeat_at": utc_now_iso(),
            "test.elapsed_seconds": 0,
            "test.bench_timeout_seconds": args.timeout,
            "pd.transfer.status": "MONITORING",
        },
    )

    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        universal_newlines=True,
        bufsize=1,
        start_new_session=True,
    )
    output_tail = []

    def stream_output():
        with args.log_file.open("w", encoding="utf-8") as log_handle:
            for line in iter(process.stdout.readline, ""):
                sys.stdout.write(line)
                sys.stdout.flush()
                log_handle.write(line)
                log_handle.flush()
                output_tail.append(line.rstrip())
                del output_tail[:-80]

    reader = threading.Thread(target=stream_output)
    reader.daemon = True
    reader.start()
    next_heartbeat = start
    reason = ""
    detail = ""

    while process.poll() is None:
        now = time.monotonic()
        elapsed = int(now - start)
        if now >= next_heartbeat:
            update_state(
                args.state,
                {"test.heartbeat_at": utc_now_iso(), "test.elapsed_seconds": elapsed},
            )
            print("BENCH_HEARTBEAT elapsed={} case={}/{}/{}".format(elapsed, args.input_len, args.output_len, args.concurrency), flush=True)
            next_heartbeat = now + args.heartbeat_interval

        for role, path in (("prefill", args.prefill_log), ("decode", args.decode_log)):
            chunk, offsets[path] = read_new(path, offsets[path])
            detected = classify_text(chunk)
            if detected:
                reason = detected
                detail = "role={}\n{}".format(role, chunk[-4000:])
                break
        if reason:
            break
        if elapsed >= args.timeout:
            reason = "bench_timeout"
            detail = "benchmark exceeded {} seconds".format(args.timeout)
            break
        time.sleep(1)

    if reason:
        stop_process(process)
    exit_code = process.wait()
    reader.join(timeout=5)
    elapsed = int(time.monotonic() - start)
    if not reason and exit_code != 0:
        reason = "bench_exit_nonzero"
        detail = "\n".join(output_tail)[-4000:]

    if reason:
        update_state(
            args.state,
            {
                "status": "BENCH_FAILED",
                "test.status": "FAILED",
                "test.heartbeat_at": utc_now_iso(),
                "test.elapsed_seconds": elapsed,
                "pd.transfer.status": "FAILED" if reason.startswith("mooncake_") else "UNKNOWN",
                "pd.transfer.failure_reason": reason,
                "pd.transfer.error_summary": detail[-4000:],
                "failure.reason": reason,
                "failure.detail": detail[-4000:],
            },
        )
        write_result(args.result_file, reason, exit_code, elapsed, detail)
        print("BENCH_WATCHDOG_FAILED reason={} elapsed={}".format(reason, elapsed), flush=True)
        return 124 if reason == "bench_timeout" else 1

    update_state(
        args.state,
        {
            "test.heartbeat_at": utc_now_iso(),
            "test.elapsed_seconds": elapsed,
            "pd.transfer.status": "READY",
            "pd.transfer.failure_reason": "",
        },
    )
    write_result(args.result_file, "", 0, elapsed, "")
    print("BENCH_WATCHDOG_DONE=1", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
