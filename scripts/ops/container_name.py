#!/usr/bin/env python3
"""Validate container names used by PD orchestration."""

import argparse
import re


DOCKER_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")


def validate_explicit_name(name, prefix):
    if not DOCKER_NAME_RE.fullmatch(name):
        raise ValueError("container_name_invalid_characters_or_length")
    if not name.startswith(prefix + "-"):
        raise ValueError("container_name_prefix_mismatch")


def validate_legacy_name(name, prefix, date, model_short, image_prefix):
    validate_explicit_name(name, prefix)
    expected = "{}-{}-{}-{}".format(prefix, date, model_short, image_prefix)
    if name != expected:
        raise ValueError("container_name_legacy_format_mismatch")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--legacy", action="store_true")
    parser.add_argument("--date")
    parser.add_argument("--model-short")
    parser.add_argument("--image-prefix")
    args = parser.parse_args()

    try:
        if args.legacy:
            for field in ("date", "model_short", "image_prefix"):
                if not getattr(args, field):
                    raise ValueError("missing_legacy_field={}".format(field))
            validate_legacy_name(
                args.name, args.prefix, args.date, args.model_short, args.image_prefix
            )
        else:
            validate_explicit_name(args.name, args.prefix)
    except ValueError as exc:
        print("CONTAINER_NAME_INVALID={}".format(args.name))
        print("CONTAINER_NAME_ERROR={}".format(exc))
        return 2

    print("CONTAINER_NAME_VALID=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
