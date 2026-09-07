# bootstrap/: CI 자격증명 설계

**상태**: 배포 완료. hub·dev 양쪽 실제 재부트스트랩·멱등성·음성 테스트 전부 통과,
`verify.sh` drift 없음.
**작성**: 2026-08-27, 2026-09-04 전면 개정(원칙 자체가 뒤집혀 재작성).

## 1. Decision

CI 신원(GitHub OIDC → App Registration)의 권한 범위 자체는 통제하지 않는다. hub·dev
각각 자신의 구독 전체에 Owner 등가(`Actions: ["*"]`, `NotActions`는 워크로드
리소스 그룹 자기 삭제만 제외)를 부여한다. 유일한 방어선은 이 신원에 도달할 수 있는
경로다 - FIC(Federated Identity Credential)의 `subject`를 정확히 하나의 GitHub
repo·`main` 브랜치로 좁힌다. AWS 원본(`eks-reference-infra`)의 실행 Role이
`AdministratorAccess`인 것과 스코프 축에서 완전 대칭이다.

FIC subject 패턴:

```
repo:<org>/<repo>:ref:refs/heads/main
repo:<org>/<repo>:environment:<env>
```

`<org>/<repo>`는 이름이 아니라 GitHub의 org/repo 불변 ID로 조합한다(이름 기반
subject는 실제 OIDC 토큰 클레임과 맞지 않는다). 필수 리뷰어는 걸지 않는다 - 배포
브랜치 정책만으로 무인 자동화를 유지한다.

## 2. Why (배경과 근거)

원래 설계(RG 스코프 커스텀 역할 + 6~7종 "0건" 불변식)에서 이 결정으로 전환한
이유는 세 가지다.

1. AWS 원본을 실측한 결과 실행 Role은 이미 `AdministratorAccess`였다. "AWS는 신원
   자체가 얇다"는 원래 전제는 **입구** Role에만 해당했고, 실제로 Terraform이
   실행되는 **실행** Role은 IAM을 포함한 전권을 갖는다. 방어선은 권한의 크기가
   아니라 "이 실행 Role에 도달할 수 있는 경로가 신뢰 정책(GitHub OIDC `sub` claim,
   repo 단위) 하나뿐"이라는 사실 하나였다.
2. Azure도 이미 그 "도달 경로 하나" 방어선을 동등한 강도로 갖는다. FIC의 `subject`가
   이 repo 하나로 스코프돼 있고, Entra 토큰도 워크플로 실행당 federated 교환으로
   발급되는 세션 토큰이라 영구 secret이 아니다.
3. CI가 `roleAssignments/write`를 갖지 못한다는 이전 제약이 사라지자, workbench·AKS
   identity 같은 산출물을 처음부터 Terraform으로 만들 수 있게 됐다 - 이게 이
   전환의 직접적 실익이었다.

Azure ABAC 조건부 위임(`roleAssignments/write`에 `RoleDefinitionId` 허용목록 조건을
거는 기능, GA·무료)도 검토했으나 채택하지 않았다. AWS 원본도 그런 조건부 좁히기
없이 그냥 `AdministratorAccess`를 쓰므로, 이 저장소도 AWS와 완전히 대칭인 경로를
택했다.

## 3. 현재 유지되는 불변식

권한 범위 축은 포기했지만, "이 신원에 누가 도달할 수 있는가"를 지키는 불변식은
그대로 유지되고, 오히려 지금은 이게 방어선의 전부다.

- Entra 디렉터리 역할 0건
- Microsoft Graph 앱 권한 0건
- 정적 자격증명(client secret·certificate) 0건 - FIC만이 유일한 인증 경로
- FIC의 `subject`·`issuer`·`audience` 전 필드가 허용 목록과 완전 일치
- 이 신원의 Entra 그룹 멤버십(transitive) 0건 - `az role assignment list
  --include-groups`는 서비스 주체에는 작동하지 않아, 그룹 경유로 권한이 얹히는
  경로를 열어둘 수 없다

`verify.sh`는 이 중 ARM 스코프 검사(구독에 워크로드 역할 할당이 정확히 1건 존재)만
CI가 Reader 권한으로 무인 실행한다. Entra 디렉터리·Graph 앱 권한 검사는 그 자체가
CI 신원에 금지된 Graph 권한을 요구하므로 사람 관리자가 수동으로 실행한다 - 이건
설계 결함이 아니라 Azure 구조의 귀결이다.

## 4. 워크로드 역할

```
Actions:    ["*"]
NotActions: ["Microsoft.Resources/subscriptions/resourceGroups/delete"]
스코프:      구독 전체
```

`resourceGroups/delete` 제외는 보안 경계가 아니라 사고 방지 안전망이다 - "실수로
`tofu destroy`가 RG 자체를 지우는" 흔한 사고를 막는 값싼 장치일 뿐, Owner는 어차피
RG 안의 모든 리소스를 지울 수 있어 admin 신원이 압축됐을 때의 방어선은 아니다.

역할 정의는 `bootstrap/config.sh`의 `workload_role_definition_json`이 만든다.

⚠️ `az role definition update`(id가 있는 경우)는 카멜케이스 변환 후
`role_definition["roleName"]`을 직접 읽는데, `create`는 `role_definition.get("name")`을
읽는다(azure-cli 2.89.1 실측) - 같은 명령군인데 요구 키가 다르다. `Name`과
`RoleName`을 둘 다 넣어 두 경로를 모두 만족시킨다.

## 5. state backend 보호

원본은 S3 + `use_lockfile = true`. Azure 대응은 `azurerm` backend(Storage Account +
Blob Container), `use_azuread_auth = true`.

**Azure RBAC는 control-plane(`Actions`)과 storage blob data-plane(`DataActions`)이
완전히 분리된 축이다.** `Owner`조차 `DataActions: []`다(`az role definition list
--name Owner`로 실측 확인). `use_azuread_auth = true`를 쓰는 이상 blob(tfstate 파일
자체) 읽기·쓰기는 워크로드 역할이 아무리 넓어도 커버되지 않고, 반드시 별도
`DataActions`를 가진 역할이 필요하다. 그래서 워크로드 역할이 구독 전체 Owner가 된
뒤에도 state 데이터 역할은 그대로 유지한다(Storage Blob Data Contributor에서
`containers/delete`만 뺀 델타, 컨테이너 스코프).

```
Actions:     containers/read, containers/write, generateUserDelegationKey/action
             (containers/delete만 제외)
DataActions: blobs/read, blobs/write, blobs/add/action, blobs/delete, blobs/move/action
스코프:       state 컨테이너
```

`containers/delete`를 제외해 컨테이너 자체는 지울 수 없게 하고, Blob 버전 관리
(soft delete + versioning)와 컨테이너 소프트 삭제를 함께 켠다. **tfstate의 실제
보호는 resource lock이 아니라 이 조합이다** - `CannotDelete` 리소스 잠금은
control-plane 사고(계정·컨테이너 자체 삭제)만 막고 blob 데이터는 보호하지 않는다.
state RG의 `CannotDelete` 잠금은 이제 "CI가 admin이라 스스로 못 푼다"는 보안
경계가 아니라 사람의 실수를 막는 안전망으로 격이 내려간다.

⚠️ CI는 `containers/write`를 유지하므로, 소프트 삭제된 컨테이너와 같은 이름으로
새 컨테이너를 만들면 그 소프트 삭제분은 영구히 복구 불가능해진다. 컨테이너 이름
재사용을 금지한다.

## 6. 재검토 트리거

CI 신원의 FIC `subject`에 와일드카드가 들어가거나, 그 `subject`가 가리키는 GitHub
repo·브랜치 보호 규칙이 완화되면 이 설계 전체를 재검토한다(CLAUDE.md ⛔ 참고).

## 7. 실행 중 발견한 재사용 가능한 버그 3건

hub·dev 재부트스트랩 실행 중 이 저장소의 다른 bash 스크립트에도 재발 가능한
일반적 교훈 3건을 발견·수정했다.

1. **az CLI `role definition update`가 `create`와 다른 키를 요구한다**(위 4절).
2. **bash `VAR=val cmd <<<"$(fn)"` 접두사 할당이 `fn` 내부까지 새어 들어간다**
   (POSIX 단순 명령의 표준 동작, bash 버전 무관). `verify.sh`가
   `IFS='|' read -r a b c <<<"$(fn)"` 한 줄로 다중 반환값을 파싱했는데, `fn` 내부의
   `for sub in $subs`(기본 IFS 기대)가 `IFS='|'`를 그대로 물려받아 구독 2개가 한
   토큰으로 뭉쳤다. 해법: 명령 치환을 먼저 순수 변수 대입으로 캡처한 뒤, 그
   문자열에만 `IFS=구분자 read`를 적용한다 - 여러 값을 반환하는 함수를 `IFS=구분자
   read <<<"$(fn)"`로 직접 파싱하지 않는다.
3. **역할 정의의 `AssignableScopes`를 update로 바꾼 직후 role assignment 생성이
   `RoleAssignmentScopeNotAssignableToRoleDefinition`으로 거부됐다**(dev 실측,
   hub는 우연히 안 걸림) - ARM 캐시 전파 지연의 새 얼굴이다.
   `retry_on_replication_delay`(`config.sh`)의 재시도 대상 오류 문자열에 추가해
   흡수했다(재시도 2회로 해소).

## 8. 마이그레이션 이력 (요약)

이 설계는 처음에 RG 스코프 커스텀 역할 + 구독/관리 그룹 role assignment 0건 등
6~7종 "0건" 불변식으로 시작했다(architect·critic 교차검증 5회 반복 합의). 실제
hub 부트스트랩 검증 과정에서 관리 그룹 스코프 검사가 실행 전제보다 훨씬 넓은
테넌트 루트 권한을 검증자에게 요구하는 과설계로 드러나 삭제했고, 이후 workbench·
AKS identity를 Terraform으로 옮기려는 시도에서 "CI가 `roleAssignments/write`를
갖지 못한다"는 제약 자체가 이 좁은 스코프 설계의 근본 이유였음이 드러났다. AWS
원본을 재확인한 결과 그 제약이 애초에 AWS에는 없었음을 확인하고(위 2절),
2026-09-04 현재 설계(1~6절)로 전환했다. hub·dev 양쪽 실제 재부트스트랩·멱등성·
음성 테스트 전부 통과 확인했다.

전환과 함께 `live/hub/aks`의 AKS identity·role assignment도 bootstrap에서
Terraform(`live/hub/aks/main.tf`의 `azurerm_user_assigned_identity`·
`azurerm_role_assignment`)으로 이관했다 - 옛 제약이 사라져 bootstrap이 만들
구조적 이유가 없어졌기 때문이다.

크로스 구독 vWAN 연결 권한(`peer/action` 단일 액션, dev 워크로드 RG 스코프)은
이 설계와 별개 축이라 `docs/decisions/live-hub-vwan-dev-networking.md`가
다룬다.
