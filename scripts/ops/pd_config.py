#!/usr/bin/env python3
"""Load the constrained PD task YAML format and emit shell variables."""

import argparse
import json
import re
import shlex
from copy import deepcopy
from pathlib import Path


def strip_comment(line):
    quote = None
    out = []
    for ch in line:
        if ch in {'"', "'"}:
            if quote == ch:
                quote = None
            elif quote is None:
                quote = ch
            out.append(ch)
        elif ch == "#" and quote is None:
            break
        else:
            out.append(ch)
    return "".join(out).rstrip()


def parse_scalar(value):
    value = value.strip()
    if value in {"", "null", "Null", "NULL", "~"}:
        return None
    if value in {"true", "True", "TRUE"}:
        return True
    if value in {"false", "False", "FALSE"}:
        return False
    if (value.startswith('"') and value.endswith('"')) or (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        if not inner:
            return []
        items, token, quote = [], [], None
        for ch in inner:
            if ch in {'"', "'"}:
                if quote == ch:
                    quote = None
                elif quote is None:
                    quote = ch
                token.append(ch)
            elif ch == "," and quote is None:
                items.append(parse_scalar("".join(token).strip()))
                token = []
            else:
                token.append(ch)
        items.append(parse_scalar("".join(token).strip()))
        return items
    if re.fullmatch(r"[-+]?[0-9]+", value):
        return int(value)
    if re.fullmatch(r"[-+]?[0-9]+\.[0-9]+", value):
        return float(value)
    return value


def parse_simple_yaml(path):
    root = {}
    stack = [(-1, root)]
    for raw in Path(path).read_text(encoding="utf-8-sig").splitlines():
        line = strip_comment(raw)
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip(" "))
        stripped = line.strip()
        if ":" not in stripped:
            raise SystemExit(f"Unsupported YAML line: {raw}")
        key, value = stripped.split(":", 1)
        key, value = key.strip(), value.strip()
        while stack and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]
        if value:
            parent[key] = parse_scalar(value)
        else:
            child = {}
            parent[key] = child
            stack.append((indent, child))
    return root


def load_yaml(path):
    try:
        import yaml  # type: ignore
    except Exception:
        return parse_simple_yaml(path)
    with open(path, "r", encoding="utf-8-sig") as fh:
        return yaml.safe_load(fh) or {}


def deep_merge(base, override):
    result = deepcopy(base)
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = deepcopy(value)
    return result


def resolve_profile(config_path, profile_ref):
    ref = Path(str(profile_ref))
    skill_root = Path(__file__).resolve().parents[2]
    candidates = []
    if ref.is_absolute():
        candidates.append(ref)
    else:
        if str(ref).startswith("references/") or str(ref).startswith("references\\"):
            candidates.append(skill_root / ref)
        candidates.append(config_path.parent / ref)
        for parent in config_path.parents:
            candidates.append(parent / ref)
        candidates.append(skill_root / ref)

    seen = set()
    for candidate in candidates:
        resolved = candidate.resolve(strict=False)
        if resolved in seen:
            continue
        seen.add(resolved)
        if candidate.exists():
            return candidate
    raise SystemExit(f"PD profile not found: {profile_ref}")

def load_with_profile(config_path):
    config_path = Path(config_path).resolve()
    config = load_yaml(config_path)
    profile_ref = (config.get("pd") or {}).get("profile")
    if not profile_ref:
        return config
    profile = load_yaml(resolve_profile(config_path, profile_ref))
    profile.pop("pd_profile", None)
    return deep_merge(profile, config)


def resolve_named_file(value, directory, suffix=".yaml"):
    path = Path(str(value)).expanduser()
    skill_root = Path(__file__).resolve().parents[2]
    candidates = [path] if path.is_absolute() else [Path.cwd() / path, skill_root / path]
    if not path.is_absolute() and len(path.parts) == 1:
        name = path.name if path.name.endswith(suffix) else path.name + suffix
        candidates.append(skill_root / "references" / directory / name)
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise SystemExit("{} not found: {}".format(directory.rstrip("s"), value))


def compose_config(config=None, profile=None, deployment=None, test_preset=None):
    data = {}
    sources = []
    if profile:
        path = resolve_named_file(profile, "pd-profiles")
        part = load_yaml(path)
        part.pop("pd_profile", None)
        data = deep_merge(data, part)
        sources.append(str(path))
    if deployment:
        path = resolve_named_file(deployment, "deployments")
        data = deep_merge(data, load_yaml(path))
        sources.append(str(path))
    if test_preset:
        path = resolve_named_file(test_preset, "test-presets")
        data = deep_merge(data, load_yaml(path))
        sources.append(str(path))
    if config:
        path = Path(config).expanduser().resolve()
        data = deep_merge(data, load_with_profile(path))
        sources.append(str(path))
    data.setdefault("config_sources", sources)
    return data


def flatten(data, prefix=""):
    if isinstance(data, dict):
        for key, value in data.items():
            name = f"{prefix}_{key}" if prefix else str(key)
            yield from flatten(value, name)
    else:
        yield prefix, data


def shell_name(name):
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_").upper()


def shell_value(value):
    if value is None:
        return ""
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, list):
        return " ".join(str(v) for v in value)
    return str(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    parser.add_argument("--profile")
    parser.add_argument("--deployment")
    parser.add_argument("--test-preset")
    parser.add_argument("--shell", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if not args.config and not args.profile:
        raise SystemExit("pass --config or --profile")
    data = compose_config(args.config, args.profile, args.deployment, args.test_preset)
    if args.json:
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return
    if args.shell:
        for key, value in flatten(data):
            print(f"{shell_name(key)}={shlex.quote(shell_value(value))}")
        return
    raise SystemExit("pass --shell or --json")


if __name__ == "__main__":
    main()
