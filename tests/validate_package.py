from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_SKILLS = {
    "workflow", "setup-workflow", "implement", "tdd", "code-review", "diagnosing-bugs",
    "resolving-merge-conflicts", "codebase-design",
}
FORBIDDEN = (
    "signapse-group",
    "signapse-ui",
    "D:/Github/signapse",
    "D:\\Github\\signapse",
    "../../../AGENTS.md",
    "../../../WORKFLOW.md",
    "../../../docs/",
)
LINK = re.compile(r"\[[^\]]+\]\(([^)]+)\)")
FENCED_CODE = re.compile(r"```.*?```", re.DOTALL)


def fail(message: str) -> None:
    print(f"ERROR: {message}")
    raise SystemExit(1)


def main() -> None:
    actual = {path.parent.name for path in (ROOT / "skills").glob("*/SKILL.md")}
    missing = sorted(REQUIRED_SKILLS - actual)
    if missing:
        fail(f"missing skills: {', '.join(missing)}")
    unexpected = sorted(actual - REQUIRED_SKILLS)
    if unexpected:
        fail(f"unexpected skills: {', '.join(unexpected)}")

    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".md", ".yaml", ".json", ".py", ".sh"}:
            continue
        if path.resolve() == Path(__file__).resolve():
            continue
        raw = path.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            fail(f"UTF-8 BOM is not allowed: {path.relative_to(ROOT)}")
        text = raw.decode("utf-8")
        if "\r\n" in text:
            fail(f"CRLF is not allowed: {path.relative_to(ROOT)}")
        if path.is_relative_to(ROOT / "skills"):
            for token in FORBIDDEN:
                if token.lower() in text.lower():
                    fail(f"forbidden coupling {token!r}: {path.relative_to(ROOT)}")
        if path.suffix.lower() == ".md":
            prose = FENCED_CODE.sub("", text)
            for target in LINK.findall(prose):
                if target.startswith(("http://", "https://", "#")) or "://" in target:
                    continue
                local = target.split("#", 1)[0]
                if local and not (path.parent / local).resolve().exists():
                    fail(f"broken link {target!r}: {path.relative_to(ROOT)}")

    print(f"Package validation passed with {len(actual)} skills.")


if __name__ == "__main__":
    main()
