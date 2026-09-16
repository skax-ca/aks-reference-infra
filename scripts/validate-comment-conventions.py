#!/usr/bin/env python3
# iac-module-library docs/conventions.md 「주석」에서 이식. 규칙 SSOT는 그 문서다. 여기서 규칙
# 텍스트를 다시 쓰지 않는다. 기계로 판정 가능한 것만 잡는다:
#
#  1. 주석 줄의 외부 참조: "§", 결정 식별자(D-XX·D25 등), 문서 절 번호("N절"). 가리키는 쪽이
#     움직이면 주석이 조용히 틀려진다. 가리키던 내용을 본문으로 옮겨 쓴다.
#  2. 주석 줄의 이력 서술: 날짜(YYYY-MM-DD), "실측" 같은 사건 서술. 통째로 지운다. 언제 누가
#     왜 바꿨는지는 git blame과 커밋 메시지가 답한다.
#
#  적용 범위: live/**/*.tf · bootstrap/*.sh · scripts/*.{sh,py} · .githooks/* ·
#  .claude/skills/**/*.sh · .github/workflows/*.yml. .terraform/ 아래는 upstream 코드라 제외한다.
#
#  실행 (repo 루트에서): python3 scripts/validate-comment-conventions.py [파일...]
#  인자를 안 주면 적용 범위 전체를 스캔한다.

import glob
import re
import sys

# (범주, 패턴, 라벨). 범주가 고치는 방향을 가른다. 순서는 바꾸지 않는다 - 한 줄에 둘 이상
# 걸릴 때 보고 순서가 달라진다.
CHECKS = [
    ("외부 참조", re.compile("§"), "'§' 인용"),
    ("외부 참조", re.compile(r"\bD-[A-Z]|\bD\d{2}\b"), "결정 식별자"),
    ("이력 서술", re.compile(r"\b20\d{2}-\d{2}-\d{2}\b"), "날짜"),
    ("외부 참조", re.compile(r"[0-9]+절"), "문서 절 번호"),
    ("이력 서술", re.compile("실측"), "사건 서술('실측')"),
]

# 검증 스크립트 둘은 규칙을 검출하느라 금지 문자를 리터럴로 담는다. 검사 대상에서 뺀다.
VALIDATORS = {
    "scripts/validate-comment-conventions.py",
    "scripts/validate-doc-conventions.py",
}


def default_targets() -> list[str]:
    targets = set()
    for pattern in (
        "live/**/*.tf",
        "bootstrap/*.sh",
        "scripts/*.sh",
        "scripts/*.py",
        ".githooks/*",
        ".claude/skills/**/*.sh",
        ".github/workflows/*.yml",
    ):
        targets |= set(glob.glob(pattern, recursive=True))
    return sorted(t for t in targets if "/.terraform/" not in t and t not in VALIDATORS)


def comment_part(line: str) -> str | None:
    """주석 부분만 돌려준다. 주석이 없으면 None."""
    stripped = line.lstrip()
    if stripped.startswith("#"):
        return stripped
    # 인라인 주석. 문자열 안의 #(예: 셸 $# , 색상 코드)은 앞에 공백이 있어야 주석으로 본다.
    m = re.search(r"\s#(?![{!$])(.*)$", line)
    return m.group(0) if m else None


def check_file(path: str) -> list[str]:
    errors = []
    if path in VALIDATORS:
        return errors
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except (FileNotFoundError, UnicodeDecodeError):
        return errors
    for i, line in enumerate(lines, 1):
        c = comment_part(line)
        if c is None:
            continue
        for category, pattern, label in CHECKS:
            if pattern.search(c):
                errors.append(
                    f"{path}:{i}: 주석의 {category}({label}). 지금 성립하는 이유만 남긴다"
                )
    return errors


def main() -> int:
    targets = sys.argv[1:] or default_targets()
    all_errors = []
    for path in targets:
        all_errors.extend(check_file(path))
    if all_errors:
        for e in all_errors:
            print(f"[ERROR] {e}")
        print(f"\n주석 규칙 위반 {len(all_errors)}건")
        return 1
    print(f"주석 규칙 검사 통과: {len(targets)}개 파일")
    return 0


if __name__ == "__main__":
    sys.exit(main())
