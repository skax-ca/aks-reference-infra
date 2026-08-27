# CLAUDE.md: 프로젝트 규칙

**읽는 사람**: 이 저장소를 스캐폴딩하거나 이후 배포·운영 작업을 하는 사람(과 Claude Code).

`iac-reference-infra`(AWS EKS hub-spoke 레퍼런스 배포 루트)와 **완전히 동일한 역할**을 Azure/AKS로
수행하는 배포 루트다. 구조·규칙·문서 체계는 전부 동일하게 유지하고, AWS 고유 메커니즘만 Azure
대응물로 치환한다. 모듈 자체는 만들지 않는다(`iac-module-library`가 담당).

## 0. 현재 상태: Phase 1 착수, Terraform/OpenTofu 코드는 아직 없음

`bootstrap/`(IaC 밖 자격증명 계층, Azure CLI bash 스크립트)는 구현 완료 + hub 대상
실제 Azure 실행 검증(3-1 멱등성·3-2 negative test 전 과정)까지 끝났다(2026-08-27,
`bootstrap/README.md` 3절 참고). 이 과정에서 버그 2건을 고치고 불변식 (b)를
제거했다 — 상세는 `.omc/plans/bootstrap-credential-design.md`의 추가 기록 참고.
dev(spoke) 인스턴스는 별도 구독이 필요해 아직 미검증이다. `live/*`(Terraform/
OpenTofu 코드)는 아직 하나도 없다 - Phase 1 networking 스캐폴딩은 별도 `plan` →
`execute`로 진행한다(6절 참고).

## 1. 이 repo의 위치 (SSOT 계층)

| repo | 역할 | SSOT |
|------|------|------|
| **이 repo (`aks-reference-infra`)** | Azure/AKS hub-spoke 패턴을 **소비해 배포**하는 루트(`iac-reference-infra`의 Azure 대응) | 이 배포 코드, 운영 절차(완성 후) |
| `iac-reference-infra` | AWS EKS 버전 원본 | 구조·문서 체계·워크플로의 1:1 참조 대상 |
| `iac-module-library` | Terraform/OpenTofu 모듈 소스(`modules/azure/`) | 모듈 계약, 네이밍 약어(`docs/naming/abbreviations/azure.md`), 아키텍처 결정 |

⚠️ **설계·컨벤션의 근거는 이 repo에 없다.** 원본과 마찬가지로 "왜 OpenTofu인가" 같은 질문은
`iac-module-library`가 갖는다. 문서 문체 규칙(em-dash 금지, 이모지 7종만 허용, 문서 간 절 번호
인용 금지, 문서당 400줄 제한)도 같은 repo의 `docs/conventions.md`가 SSOT다. 이 문서는 이미 그
규칙을 따라 작성했다.

## 2. 확정된 결정

이전 세션(HANDOFF.md, 이 저장소 초기 kickoff 메모)에서 사용자가 직접 답한 것과, 이후
`/oh-my-claudecode:ralplan`(5라운드, `.omc/plans/bootstrap-credential-design.md` v6)으로
확정한 것.

| 결정 사항 | 확정값 | 근거 |
|---|---|---|
| Terraform/OpenTofu 모듈 소스 | `iac-module-library`의 `modules/azure/` | `aws/`·`azure/` 분리 체계와 `docs/naming/abbreviations/azure.md`가 이미 존재. 단 Azure 쪽은 현재 `vnet` 모듈 1개뿐 |
| hub-spoke 네트워킹의 TGW 대응 | **Azure Virtual WAN** | 완전관리형 허브라는 점에서 TGW와 가장 가까운 개념 |
| 이번 착수 범위 | **로컬 스캐폴딩까지만** | GitHub repo 생성·push는 검토 후 별도 승인 필요 |
| 구독 분리 | **hub/dev를 별도 Azure 구독으로 분리** | 사용자 확인 완료(2026-08-27). 폭발 반경을 구독 경계에서 막는 1차 방어선 |
| bootstrap 자격증명 계층 | RG 스코프 커스텀 역할 2종 + 6종 권한 0건 불변식(`bootstrap/README.md` 참고) | ralplan 5라운드로 확정, 이후 관리 그룹 스코프 불변식은 실제 Azure 검증 세션(2026-08-27)에서 제거. 4절의 설계 보류가 해제됐다 |
| state backend | Azure Storage Account + Blob Container, `use_azuread_auth`, `allowSharedKeyAccess = false` | `azurerm` backend가 blob lease 잠금을 네이티브 지원, S3+`use_lockfile`의 완전한 대응물 |
| GitHub Actions 배포 승인 | 배포 브랜치 정책만(필수 리뷰어 없음) | 사용자 확인 완료(2026-08-27). 무인 자동화 유지 우선 |
| Option C(MI-as-FIC 추가 계층) | 보류 | 사용자가 30분 실측 스파이크를 나중으로 미룸. 기본 설계(Option A+D)는 그 결과와 무관하게 완결된 방어선 |

## 3. 모듈 가용성에 따른 페이즈 분리

`iac-module-library`의 Azure 모듈이 `vnet` 하나뿐이라, 원본의 `live/*/networking`과
`live/*/eks`(Azure에서는 `aks`) 두 계층을 동시에 포팅할 수 없다.

- **Phase 1(지금 가능)**: `live/hub/networking`, `live/dev/networking`. `modules/azure/vnet`을
  소비한다. `live/hub/vwan`(TGW 대응, 별도 state)을 신설한다. `bootstrap/`(자격증명 계층, 4절
  참고)도 이 단계에 속한다.
- **Phase 2(블록됨)**: `live/hub/aks`, `live/dev/aks`. `iac-module-library`에 `aks` 모듈이
  올라올 때까지 보류한다. 지금은 디렉토리도 만들지 않는다. 빈 스텁을 만들면 나중에 무엇이 진짜
  완성인지 헷갈린다.

## 4. bootstrap 자격증명 계층 설계 (해제됨, `/oh-my-claudecode:ralplan` 5라운드로 확정)

원본의 `bootstrap/README.md`가 쓰는 AWS OIDC 패턴은 입구 Role(신뢰: OIDC 하나, 권한:
`AssumeRole` 하나뿐) → 실행 Role(신뢰: 입구 Role만, 권한: `AdministratorAccess`) 2단
체인이다. AWS STS의 role-chaining이 있어야 가능한 방어 구조이고, Azure Entra ID에는
이 정확한 대응 개념이 없다.

**확정된 대체 설계**(전문은 `.omc/plans/bootstrap-credential-design.md`,
구현은 `bootstrap/README.md`·`config.sh`·`bootstrap.sh`·`verify.sh`): 원본의 2단
체인을 재현하는 대신, CI 신원(App Registration)의 권한을 리소스 그룹 하나로 좁히고
그 권한이 새어나가지 않는지 6종 불변식(구독/디렉터리/Graph 권한·정적
자격증명·FIC 설정·그룹 멤버십이 전부 0건 또는 허용 목록과 완전 일치)으로 검증한다.
관리 그룹 스코프 불변식은 원래 7종에 포함됐으나, 이 설계의 OIDC 배포 경로가 관리
그룹을 전혀 쓰지 않는데도 그 부재를 증명하려면 검증자에게 테넌트 루트 MG Reader라는
불균형한 권한이 필요해 실제 Azure 검증 세션(2026-08-27)에서 제거했다.

⚠️ **원칙 1의 한계**: 이 설계는 "GitHub Actions가 직접 인증하는 신원이 그 리소스
그룹에 대한 커스텀 역할을 직접 갖는다"는 점에서, AWS 원본의 "신원 자체가 얇다"(입구
신원은 고권한을 전혀 갖지 않는다)는 속성과 완전히 같지는 않다. 이 차이는 의도적으로
받아들인 트레이드오프이며, 검증 가능한 6종 불변식으로 방어 깊이를 대체한다. Option
C(MI-as-FIC, App Registration 앞에 UAMI를 한 겹 더 두는 선택적 추가 계층)가
채택되면 이 한계가 줄어들지만, 현재는 보류 상태다(2절 표).

⛔ Phase 2에서 AKS 배포가 이 CI 신원에 `Microsoft.Authorization/roleAssignments/write`를
요구하게 되면, 자동으로 부여하지 않는다. 그 권한이 부여되는 순간 CI 신원은 자기
자신에게 상위 역할을 부여할 수 있어 이 설계 전체의 방어선이 무의미해진다. 요구가
생기면 이 설계 자체를 재검토하는 트리거로 취급한다.

state backend(원본은 S3 + `use_lockfile`)의 Azure 대응도 확정됐다: Storage Account +
Blob Container, `azurerm` backend의 네이티브 blob lease 잠금 사용, `use_azuread_auth`
+ `allowSharedKeyAccess = false`로 계정 키 우회 차단. 상세는 2절 표와
`bootstrap/README.md`("기대 상태" 절) 참고.

## 5. 저장소 구조(✅ bootstrap/는 구현 완료, 나머지는 Phase 1 완료 후 실제로 존재)

```
bootstrap/              ✅ 자격증명·state 저장소 계층(IaC 밖, 4절 설계 구현 완료)
live/hub/networking/    VNet(hub)
live/hub/vwan/          Virtual WAN(hub, networking과 분리된 state)
live/dev/networking/    VNet + Virtual WAN 연결(spoke 첫 인스턴스)
live/hub/aks/           (Phase 2, 모듈 준비 전까지 생성하지 않음)
live/dev/aks/           (Phase 2, 모듈 준비 전까지 생성하지 않음)
docs/                   운영 절차 SSOT(포팅 후) + 이 repo 고유 참조 문서
scripts/                문서 문체 검증 등(원본에서 기계적으로 이식)
```

## 6. 다음 세션이 할 일(순서)

1. ✅ `/oh-my-claudecode:deepinit`: 이 문서와 원본 구조를 원재료로 초기화 완료
2. ✅ 프로젝트 전용 세션 스킬(`.claude/skills/notepad-sync/SKILL.md`) 작성 완료
3. ✅ `bootstrap/`(자격증명 계층) 설계를 `/oh-my-claudecode:ralplan`(5라운드)으로 확정,
   `ralph`로 구현 완료(4절 참고)
4. ✅ hub 대상 실제 Azure 실행 검증 완료(2026-08-27, 3-1·3-2 전 과정). 버그 2건 수정,
   불변식 (b) 제거 — `bootstrap/README.md` 3절·설계 이력 참고
4-1. ⏳ dev(spoke) 인스턴스 검증은 별도 구독이 생기면 진행(현재 로그인 계정은 구독
   1개뿐)
5. ✅ bootstrap용 네이밍 약어 등재 완료(2026-08-27, `iac-module-library`의 `azure.md`에
   `rg`·`st`·`entapp` 3종. `entapp`는 CAF 표에 없는 첫 non-ARM 등재 사례). hub 리소스는
   삭제 후 재생성으로 이름 정리 진행 중. 크로스 구독 vWAN 권한 스코프는 여전히 미확정
   (`modules/azure/vnet` 계약 확인 후 Phase 1에서)
6. ⏳ 나머지(docs 포팅, Phase 1 networking 스캐폴딩)는 `/oh-my-claudecode:plan` → `execute`
7. ⏳ 완료 후 `/oh-my-claudecode:verify`

## 7. 문서 작성 규칙

이 repo에 `docs/*.md`·`README.md`·`CLAUDE.md`가 늘어나면 원본과 동일하게
`iac-module-library`의 `docs/conventions.md`가 정하는 규칙(문서 간 절 번호 인용 금지, 이모지는
`✅⏳❌⚠️⛔🔴🔑` 7종만, 문서당 400줄 제한, em-dash 금지)을 따른다. 검증 스크립트
(`scripts/validate-doc-conventions.py`)는 아직 이식하지 않았다. Phase 1 스캐폴딩 단계에서
원본으로부터 기계적으로 복사한다.
