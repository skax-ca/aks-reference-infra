# aks-reference-infra

**읽는 사람**: 이 저장소로 Azure hub-spoke AKS 환경을 구축하거나 철거하는 사람.

**오너**: GitHub org [`skax-ca`](https://github.com/skax-ca) 소속. 모듈·설계 문의는
[`iac-module-library`](https://github.com/skax-ca/iac-module-library)가, 플랫폼 addon 문의는
[`aks-platform-gitops`](https://github.com/skax-ca/aks-platform-gitops)가 받는다.

Azure hub-spoke AKS **배포 루트**([`eks-reference-infra`](https://github.com/skax-ca/eks-reference-infra)의
Azure 대응). `iac-module-library`의 모듈을 git tag로 소싱해 클러스터를 구축하고, ArgoCD를 심어
플랫폼 매니페스트를 `aks-platform-gitops`에 넘긴다.

⛔ **모듈 소스는 이 저장소가 아니다.** 모듈을 고칠 일이 생기면 `iac-module-library`에서 고치고
태그를 올린 뒤, 여기서 `ref=`를 그 태그로 올린다.

---

## 배포 루트

| 루트 | 무엇 | state key |
|------|------|-----------|
| [`live/hub/networking`](live/hub/networking) | hub VNet · 서브넷 · NSG · NAT Gateway | `hub/networking.tfstate` |
| [`live/hub/vwan`](live/hub/vwan) | Virtual WAN · 허브 · 스포크 연결(TGW 대응) | `hub/vwan.tfstate` |
| [`live/hub/aks`](live/hub/aks) | hub AKS · identity · role assignment | `hub/aks.tfstate` |
| [`live/hub/workbench`](live/hub/workbench) | hub 운영 지점 VM | `hub/workbench.tfstate` |
| [`live/dev/networking`](live/dev/networking) | dev VNet | `dev/networking.tfstate` |
| [`live/dev/aks`](live/dev/aks) | dev AKS · hub ArgoCD 접근 role assignment | `dev/aks.tfstate` |
| [`live/dev/workbench`](live/dev/workbench) | dev 운영 지점 VM | `dev/workbench.tfstate` |

7개 전부 별도 state다. 루트 간 결합은 `terraform_remote_state`가 아니라 Name·태그 기반 `data`
조회다. 예외는 크로스 구독이다. `live/hub/vwan`의 `spoke_connections`는 조회 대신 CI 변수로
리소스 ID를 받는다.

## 실행 모델

push가 그 루트의 plan을 돌리고, apply job은 environment(`hub`·`dev`)의 승인을 기다린다.
승인자는 그 run의 plan 요약을 읽고 누르며, 같은 run이 저장된 plan을 적용한다. destroy와 재-plan은
`workflow_dispatch` 경로이고 역시 승인을 기다린다.

⚠️ 실패한 apply는 `gh run rerun <run-id> --failed`로 이미 승인한 plan을 다시 적용한다. 새
dispatch는 새 plan이라 승인을 다시 받는다. plan artifact는 7일 보존이다.

로컬에서는 `tofu init`·`validate`까지 된다. apply·destroy는 `var.ci_run` 검사가 막는다.

## 문서

| 하려는 것 | 읽을 것 |
|-----------|---------|
| hub를 구축·철거한다 | [`docs/hub-lifecycle.md`](docs/hub-lifecycle.md) |
| spoke를 구축·철거한다 | [`docs/spoke-lifecycle.md`](docs/spoke-lifecycle.md) |
| 이미 구축된 환경을 운영한다 | [`docs/runbooks.md`](docs/runbooks.md) |
| state 저장소·CI 신원(App Registration·FIC)·역할을 만든다(IaC 밖) | [`bootstrap/README.md`](bootstrap/README.md) |
| 왜 이 패턴인가 | `iac-module-library`의 [`docs/architectures/gitops-hub-spoke/azure/`](https://github.com/skax-ca/iac-module-library/tree/main/docs/architectures/gitops-hub-spoke/azure) |

이 저장소 고유의 판단(Pod CIDR 배치, 2단 조회가 필요한 이유 등)은 해당 `.tf`·`.sh`의 인라인
주석이 갖는다. CIDR 배치는 각 루트 `main.tf`의 locals 주석이 실물이다.

## 개발 준비

```bash
brew install opentofu tflint trivy shellcheck gitleaks
git config core.hooksPath .githooks        # clone마다 1회
GITHUB_TOKEN=$(gh auth token) tflint --init
```

`.tf`·워크플로·셸 변경은 브랜치 → PR이다. `verify.yml`이 훅과 같은 게이트를 PR에서 다시 돌아
훅이 꺼진 클론과 fork PR을 막는다. 문서만 바뀌는 커밋은 `main` 직접이다.

---

## 라이선스

[MIT](LICENSE).
