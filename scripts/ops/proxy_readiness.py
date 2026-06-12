#!/usr/bin/env python3
"""Validate Mooncake proxy listener, upstreams, bootstrap, and a real PD request."""

import argparse
import json
import os
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


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
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temp.replace(path)


def bounded(text, limit=2000):
    return (text or "")[-limit:]


def log_tail(path, lines=100):
    try:
        return "\n".join(path.read_text(encoding="utf-8", errors="replace").splitlines()[-lines:])
    except OSError:
        return ""


def process_alive(pid_file):
    try:
        pid = int(pid_file.read_text(encoding="utf-8").strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return False


def request(opener, url, timeout, payload=None):
    headers = {"Accept": "application/json"}
    data = None
    method = "GET"
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
        method = "POST"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=timeout) as response:
            body = response.read().decode("utf-8", errors="replace")
            return response.status, bounded(body), ""
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return exc.code, bounded(body), ""
    except (urllib.error.URLError, socket.timeout, TimeoutError, OSError) as exc:
        return 0, "", "{}: {}".format(type(exc).__name__, exc)


def probe(opener, state, prefix, url, timeout):
    code, body, error = request(opener, url, timeout)
    status = "READY" if code == 200 else "WAITING"
    update_state(
        state,
        {
            prefix + ".status": status,
            prefix + ".url": url,
            prefix + ".http_code": code,
            prefix + ".response": body,
            prefix + ".error": error,
        },
    )
    return code == 200, code, body, error


def fail(state, reason, detail, log_file, attempts, elapsed):
    update_state(
        state,
        {
            "status": "PROXY_FAILED",
            "pd.proxy.status": "FAILED",
            "pd.proxy.attempts": attempts,
            "pd.proxy.readiness_duration_seconds": elapsed,
            "pd.proxy.log_tail": bounded(log_tail(log_file), 4000),
            "failure.reason": reason,
            "failure.detail": bounded(detail, 4000),
        },
    )
    print("PROXY_READINESS_FAILED reason={} detail={}".format(reason, bounded(detail, 500)), flush=True)
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    parser.add_argument("--pid-file", required=True, type=Path)
    parser.add_argument("--proxy-url", required=True)
    parser.add_argument("--prefill-url", required=True)
    parser.add_argument("--decode-url", required=True)
    parser.add_argument("--prefill-transfer-port", required=True, type=int)
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--interval", type=int, default=10)
    parser.add_argument("--request-timeout", type=int, default=180)
    args = parser.parse_args()

    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    prefill_host = urllib.parse.urlparse(args.prefill_url).hostname
    bootstrap_url = "http://{}:{}/query".format(prefill_host, args.prefill_transfer_port)
    start = time.monotonic()
    attempts = 0
    last_reason = "proxy_listener_timeout"
    last_detail = "proxy listener did not respond"

    update_state(
        args.state,
        {
            "status": "PROXY_WAITING_READY",
            "pd.proxy.status": "WAITING_READY",
            "pd.proxy.request_timeout_seconds": args.request_timeout,
            "pd.proxy.readiness_timeout_seconds": args.timeout,
        },
    )

    while True:
        attempts += 1
        elapsed = int(time.monotonic() - start)
        update_state(args.state, {"pd.proxy.attempts": attempts})

        if not process_alive(args.pid_file):
            return fail(args.state, "proxy_process_exited", "proxy pid is not alive", args.log, attempts, elapsed)

        fatal_log = log_tail(args.log)
        if any(token in fatal_log for token in ("Traceback", "ModuleNotFoundError", "ImportError")):
            return fail(args.state, "proxy_log_failure_signal", fatal_log, args.log, attempts, elapsed)

        ok, code, body, error = probe(
            opener, args.state, "pd.proxy.listener", args.proxy_url.rstrip("/") + "/openapi.json", 10
        )
        if not ok:
            last_reason = "proxy_listener_timeout"
            last_detail = error or "listener_http_code={} body={}".format(code, body)
        else:
            checks = [
                ("prefill", args.prefill_url.rstrip("/") + "/health", "prefill_upstream_unreachable"),
                ("decode", args.decode_url.rstrip("/") + "/health", "decode_upstream_unreachable"),
            ]
            upstream_ok = True
            for name, url, reason in checks:
                ok, code, body, error = probe(opener, args.state, "pd.proxy.upstream." + name, url, 10)
                if not ok:
                    upstream_ok = False
                    last_reason = reason
                    last_detail = error or "{}_http_code={} body={}".format(name, code, body)
                    break

            if upstream_ok:
                ok, code, body, error = probe(
                    opener, args.state, "pd.proxy.bootstrap", bootstrap_url, 10
                )
                if not ok:
                    last_reason = "prefill_bootstrap_unreachable"
                    last_detail = error or "bootstrap_http_code={} body={}".format(code, body)
                else:
                    payload = {
                        "model": args.model_id,
                        "messages": [{"role": "user", "content": "ping"}],
                        "temperature": 0,
                        "max_tokens": 1,
                        "stream": False,
                    }
                    code, body, error = request(
                        opener,
                        args.proxy_url.rstrip("/") + "/v1/chat/completions",
                        args.request_timeout,
                        payload,
                    )
                    smoke_status = "READY" if code == 200 else ("WAITING" if code == 503 else "FAILED")
                    update_state(
                        args.state,
                        {
                            "pd.proxy.smoke.status": smoke_status,
                            "pd.proxy.smoke.http_code": code,
                            "pd.proxy.smoke.response": body,
                            "pd.proxy.smoke.error": error,
                        },
                    )
                    if code == 200:
                        update_state(
                            args.state,
                            {
                                "status": "PROXY_READY",
                                "pd.proxy.status": "READY",
                                "pd.proxy.readiness_duration_seconds": elapsed,
                                "pd.proxy.served_model_id": args.model_id,
                                "pd.proxy.served_model_id_source": "decode",
                            },
                        )
                        print("PROXY_READY=1", flush=True)
                        print("PROXY_SERVED_MODEL_ID={}".format(args.model_id), flush=True)
                        return 0
                    if code == 503:
                        last_reason = "proxy_upstream_not_ready"
                        last_detail = body or "proxy returned 503"
                    elif 400 <= code < 500:
                        return fail(
                            args.state,
                            "proxy_smoke_http_error",
                            "http_code={} body={}".format(code, body),
                            args.log,
                            attempts,
                            elapsed,
                        )
                    elif error and ("timed out" in error.lower() or "timeout" in error.lower()):
                        last_reason = "proxy_smoke_timeout"
                        last_detail = error
                    else:
                        last_reason = "proxy_smoke_http_error"
                        last_detail = error or "http_code={} body={}".format(code, body)

        if elapsed >= args.timeout:
            return fail(args.state, last_reason, last_detail, args.log, attempts, elapsed)
        print(
            "PROXY_WAITING attempt={} elapsed={} reason={} detail={}".format(
                attempts, elapsed, last_reason, bounded(last_detail, 300)
            ),
            flush=True,
        )
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
