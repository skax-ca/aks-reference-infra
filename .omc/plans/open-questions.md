# Open Questions

계획 전반에서 미해결로 남은 결정·확인 사항을 한 곳에 모은다. 계획별로 append 한다.

## live/hub/vwan + live/dev/networking - 2026-08-28

- [x] 🔴 dev Pod CIDR을 `100.64.0.0/16`(hub와 중복)에서 `100.65.0.0/16`(고유)으로
      바꾸는 것 — **사용자 승인 완료(2026-08-28)**. Pod 트래픽이 vWAN 허브를 건너게
      되는 것(NSG가 유일한 보상 통제)도 함께 승인됨.
- [x] dev VNet의 `deletion_protection` — **사용자 결정: `true`(hub와 동일)**.
- [ ] Azure Firewall을 vWAN 허브에 둘 것인가 - 지금 답할 필요는 없으나 vHub 주소
      공간을 `/22`로 잡을지가 여기 걸린다. vHub 주소 공간은 생성 후 변경 불가다.
- [ ] `azurerm_virtual_hub_connection`이 "Propagate to none"을 어떤 인자 형태로
      표현하는지 미확인 - Pod CIDR 고유화(Option A)를 택하면 무관해진다.
- [ ] 같은 vWAN 허브에 주소가 겹치는 VNet 연결이 생성 단계에서 거부되는지 미실측 -
      마찬가지로 Option A를 택하면 무관해진다.
- [ ] `scripts/validate-doc-conventions.py` 이식 시점 - hub bootstrap 단계부터 밀려
      있다. 문서가 늘어날수록 소급 적용 비용이 커진다.
- [ ] hub 워크플로의 repo 변수 이름을 `AZURE_CLIENT_ID`에서 `AZURE_HUB_CLIENT_ID`로
      바꾸는 시점 - 동작 중인 파이프라인 변경이라 별도 커밋으로 분리해야 한다.
