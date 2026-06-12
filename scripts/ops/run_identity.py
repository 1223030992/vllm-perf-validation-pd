#!/usr/bin/env python3
"""Generate and validate isolated PD run identities."""

import argparse
import re
import secrets
import shlex
from datetime import datetime


RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


def new_invocation_id(now=None):
    current = now or datetime.now()
    return "{}-{}".format(current.strftime("%Y%m%d-%H%M%S"), secrets.token_hex(4))


def resolve_run_id(model_short, mode, requested="", invocation_id=None):
    invocation = invocation_id or new_invocation_id()
    run_id = requested or "{}-{}-{}".format(model_short, mode, invocation)
    if not RUN_ID_RE.fullmatch(run_id):
        raise ValueError("invalid_run_id={}".format(run_id))
    return invocation, run_id


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-short", required=True)
    parser.add_argument("--mode", required=True)
    parser.add_argument("--run-id", default="")
    parser.add_argument("--shell", action="store_true")
    args = parser.parse_args()
    try:
        invocation, run_id = resolve_run_id(args.model_short, args.mode, args.run_id)
    except ValueError as exc:
        raise SystemExit(str(exc))
    if args.shell:
        print("INVOCATION_ID={}".format(shlex.quote(invocation)))
        print("RUN_ID={}".format(shlex.quote(run_id)))
    else:
        print(run_id)


if __name__ == "__main__":
    main()
