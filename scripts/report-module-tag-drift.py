#!/usr/bin/env python3
"""배포 루트들이 같은 모듈을 서로 다른 태그로 소싱하고 있는지 보고한다.

  적용 범위: live/**/*.tf 의 source 인자에 박힌 "?ref=<컴포넌트>-v<x.y.z>".
  실행 (repo 루트에서): python3 scripts/report-module-tag-drift.py

⚠️ 이 스크립트는 실패하지 않는다. 종료 코드는 항상 0 이다. 갈린 상태가 의도일 때
   (한 루트만 먼저 올려 보는 스테이지드 승격) 게이트를 막으면 그 방식 자체가 불가능해진다.
   판단은 사람이 하고, 이 출력은 "갈려 있다는 사실을 몰랐다"만 없앤다.

⚠️ 드리프트는 스테이지드 승격 말고 Dependabot 으로도 생긴다. .github/dependabot.yml 이
   루트마다 디렉토리를 따로 걸어서, 같은 모듈의 같은 버전 올림이 루트 수만큼 별개 PR 로
   열린다. 짝 중 하나만 머지하면 그 순간 갈린다.

GITHUB_STEP_SUMMARY 가 있으면 거기에, 없으면 표준 출력에 쓴다.
"""

from __future__ import annotations

import glob
import os
import re
import sys
from collections import defaultdict

# source = "git::https://...//modules/aws/vpc?ref=vpc-v0.5.0&depth=1"
REF = re.compile(r"\?ref=([a-z0-9][a-z0-9-]*)-v(\d+\.\d+\.\d+)")

# live/<env>/<root>/*.tf → "live/<env>/<root>"
ROOT_DEPTH = 3


def root_of(path: str) -> str:
    return "/".join(path.split("/")[:ROOT_DEPTH])


def collect() -> dict[str, dict[str, list[str]]]:
    """{컴포넌트: {버전: [루트...]}}"""
    found: dict[str, dict[str, list[str]]] = defaultdict(lambda: defaultdict(list))
    for path in sorted(glob.glob("live/**/*.tf", recursive=True)):
        if "/.terraform/" in path:
            continue
        with open(path, encoding="utf-8") as handle:
            for component, version in REF.findall(handle.read()):
                root = root_of(path)
                if root not in found[component][version]:
                    found[component][version].append(root)
    return found


def render(found: dict[str, dict[str, list[str]]]) -> tuple[str, int]:
    lines = ["### 모듈 태그", ""]
    drifted = 0
    if not found:
        lines.append("git 태그로 소싱하는 모듈이 없다.")
        return "\n".join(lines) + "\n", drifted

    lines += ["| 모듈 | 버전 | 루트 |", "|---|---|---|"]
    for component in sorted(found):
        versions = found[component]
        mark = "⚠️ " if len(versions) > 1 else ""
        if len(versions) > 1:
            drifted += 1
        for version in sorted(versions):
            roots = " · ".join(f"`{r}`" for r in sorted(versions[version]))
            lines.append(f"| {mark}`{component}` | `v{version}` | {roots} |")

    lines.append("")
    if drifted:
        lines.append(
            f"⚠️ **{drifted}개 모듈이 루트마다 다른 태그를 쓴다.** 의도한 것이 아니면 맞춘다. "
            "Dependabot 이 연 짝 PR 중 일부만 머지하면 이 상태가 된다."
        )
    else:
        lines.append("루트 간 태그가 전부 같다.")
    return "\n".join(lines) + "\n", drifted


def main() -> int:
    body, drifted = render(collect())
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(body)
    print(body, end="")
    if drifted:
        # 게이트를 막지 않는다. 로그에서 눈에 띄게만 한다.
        print(f"::warning::모듈 태그가 루트마다 갈린 것이 {drifted}건이다")
    return 0


if __name__ == "__main__":
    sys.exit(main())
