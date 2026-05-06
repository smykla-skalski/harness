#!/usr/bin/env python3
"""Patch generated Xcode run-scheme environment variables."""

from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def env_value_args(raw_args: list[str]) -> list[tuple[str, str]]:
    pairs: list[tuple[str, str]] = []
    for raw in raw_args:
        key, separator, value = raw.partition("=")
        if not separator or not key:
            raise SystemExit(f"invalid environment argument: {raw}")
        pairs.append((key, value))
    return pairs


def launch_environment_element(launch_action: ET.Element) -> ET.Element:
    environment = launch_action.find("EnvironmentVariables")
    if environment is not None:
        return environment

    environment = ET.Element("EnvironmentVariables")
    children = list(launch_action)
    for index, child in enumerate(children):
        if child.tag == "CommandLineArguments":
            launch_action.insert(index + 1, environment)
            return environment

    launch_action.append(environment)
    return environment


def patch_environment_variable(
    environment: ET.Element,
    key: str,
    value: str,
) -> None:
    for variable in environment.findall("EnvironmentVariable"):
        if variable.attrib.get("key") == key:
            variable.set("value", value)
            variable.set("isEnabled", "YES")
            return

    ET.SubElement(
        environment,
        "EnvironmentVariable",
        {"key": key, "value": value, "isEnabled": "YES"},
    )


def patch_scheme(path: Path, pairs: list[tuple[str, str]]) -> None:
    tree = ET.parse(path)
    root = tree.getroot()
    launch_action = root.find("LaunchAction")
    if launch_action is None:
        raise SystemExit(f"missing LaunchAction in {path}")

    environment = launch_environment_element(launch_action)
    for key, value in pairs:
        patch_environment_variable(environment, key, value)

    ET.indent(tree, space="   ")
    tree.write(path, encoding="UTF-8", xml_declaration=True)


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(
            "usage: patch-run-scheme-env.py <scheme.xcscheme> KEY=VALUE ...",
            file=sys.stderr,
        )
        return 2

    patch_scheme(Path(argv[1]), env_value_args(argv[2:]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
