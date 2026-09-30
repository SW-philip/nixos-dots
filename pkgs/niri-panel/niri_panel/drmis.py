import json
import subprocess


def parse_list(stdout: str) -> list:
    return json.loads(stdout)


def list_themes() -> list:
    return parse_list(subprocess.run(
        ["drmis", "list", "--json"],
        capture_output=True, text=True, check=True,
    ).stdout)


def set_theme(slug: str) -> None:
    subprocess.run(["drmis", "set", slug], check=True)
