#!/usr/bin/env python3
# iac-module-library docs/writing-style.md(「구조 규칙」·「문체 규칙」)에서 이식. 규칙 SSOT는 그
# 문서다. 여기서 규칙 텍스트를 다시 쓰지 않는다. 기계로 판정 가능한 4개만 검사하고 나머지("읽는
# 사람" 첫 줄, 변경 이력 금지, 표/명령, 정정 서술 금지, 문체 규칙 대부분)는 문맥 판단이 필요해
# 자동화하지 않는다. 억지로 정규식화하면 오탐이 사람 검토보다 비싸진다.
#
#  1. 구조 규칙 6: 문서 간 §N 인용 금지. "§" 문자 자체가 정당한 용례가 없으므로(자기 절 번호도
#     "## 8." 형식이지 "§8"이 아니다) "§" 등장 자체를 위반으로 본다.
#  2. 구조 규칙 3: 이모지는 고정 7종(✅⏳❌⚠️⛔🔴🔑)만 허용. 그 밖의 이모지 범위 문자를 잡는다.
#  3. 구조 규칙 4: 문서 400줄 제한. 데이터 카탈로그는 규칙이 명시한 예외라 건너뛴다.
#  4. 문체 규칙 6: em-dash("—") 금지.
#
#  적용 범위: 구조 규칙이 스스로 선언한 범위와 같다. docs/*.md · 저장소 전역 README.md·AGENTS.md ·
#  루트 CLAUDE.md.
#
#  실행 (repo 루트에서): python3 scripts/validate-doc-conventions.py [파일...]
#  인자를 안 주면 적용 범위 전체를 스캔한다.

import glob
import re
import sys

ALLOWED_EMOJI = {"✅", "⏳", "❌", "⚠️", "⛔", "🔴", "🔑"}
LINE_LIMIT = 400
# 이 repo에는 규칙이 예외로 명시한 데이터 카탈로그(약어표)가 없다. 약어표는 iac-module-library가
# 갖는다. 그런 문서가 생기면 여기 경로를 추가한다.
LINE_LIMIT_EXCEPTIONS: set[str] = set()

# 이모지가 몰려 있는 유니코드 블록 두 개만 본다. 주 이모지 블록(1F300-1FAFF)과 misc symbols·
# dingbats(2600-27BF). "→"·"⇒"·"↔" 같은 화살표 블록(2190-21FF·2B00-2BFF)은 일부러 뺐다. 이
# 저장소가 "A → B"처럼 산문 연결 기호로 광범위하게 쓰고 있어서, 그 블록을 넣으면 구조 규칙 3
# (장식용 이모지 7종 제한)과 무관한 화살표까지 대량 오탐된다.
# ⚠️ 알려진 한계: 2B00-2BFF 블록(별 기호 포함, 예 ⭐)은 화살표와 뒤섞여 있어 이 스캐너가 못
#    잡는다. 그 블록에서 오탐 없이 별 기호만 추리려면 개별 코드포인트 목록이 필요한데 지금은
#    그 비용을 들이지 않는다(신규 위반 예방이 목적이지 과거 소급 전수 검출이 아니다).
EMOJI_PATTERN = re.compile("[\U0001F300-\U0001FAFF☀-➿]")


def default_targets() -> list[str]:
    targets = set(glob.glob("docs/*.md"))
    targets |= set(glob.glob("**/README.md", recursive=True))
    targets |= set(glob.glob("**/AGENTS.md", recursive=True))
    targets.add("CLAUDE.md")
    return sorted(targets)


def strip_fenced_code(lines: list[str]) -> list[bool]:
    """줄 인덱스별로 코드펜스(``` ... ```) 안인지 표시한다.

    펜스 안은 예시 명령·출력이라 "§"·이모지가 리터럴로 등장해도 위반이 아니다
    (예: docs/conventions.md의 grep 예시가 검색 대상으로 "§"를 쓴다).
    """
    in_fence = [False] * len(lines)
    inside = False
    for i, line in enumerate(lines):
        if line.strip().startswith("```"):
            inside = not inside
            in_fence[i] = True  # 펜스 여는/닫는 줄 자체도 제외
            continue
        in_fence[i] = inside
    return in_fence


def check_file(path: str) -> list[str]:
    errors = []
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        return errors
    lines = text.splitlines()
    in_fence = strip_fenced_code(lines)

    if "§" in text:
        for i, line in enumerate(lines, 1):
            if in_fence[i - 1]:
                continue
            if "§" in line:
                errors.append(f"{path}:{i}: 구조 규칙 6 위반: '§' 인용. 문서 링크 또는 「절 제목」 참조로 바꾼다")

    for i, line in enumerate(lines, 1):
        if in_fence[i - 1]:
            continue
        for ch in EMOJI_PATTERN.findall(line):
            # VS16이 붙은 조합(⚠️·❌ 등)은 그 조합 전체로 다시 판정한다.
            combined = ch + ("️" if line[line.find(ch) + 1 : line.find(ch) + 2] == "️" else "")
            if ch not in ALLOWED_EMOJI and combined not in ALLOWED_EMOJI:
                errors.append(f"{path}:{i}: 구조 규칙 3 위반: 비표준 이모지 '{ch}' (허용 7종: ✅⏳❌⚠️⛔🔴🔑)")

    if path not in LINE_LIMIT_EXCEPTIONS and len(lines) > LINE_LIMIT:
        errors.append(f"{path}: 구조 규칙 4 위반: {len(lines)}줄 (한도 {LINE_LIMIT}줄)")

    for i, line in enumerate(lines, 1):
        if in_fence[i - 1]:
            continue
        if "—" in line:
            errors.append(f"{path}:{i}: 문체 규칙 6 위반: em-dash('—'). 마침표·쉼표·괄호로 바꾼다")

    return errors


def main() -> int:
    targets = sys.argv[1:] or default_targets()
    all_errors = []
    for path in targets:
        all_errors.extend(check_file(path))

    if all_errors:
        for e in all_errors:
            print(f"[ERROR] {e}")
        print(f"\n문서 작성 규칙 위반 {len(all_errors)}건")
        return 1

    print(f"문서 작성 규칙 검사 통과: {len(targets)}개 파일")
    return 0


if __name__ == "__main__":
    sys.exit(main())
