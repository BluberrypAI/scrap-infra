# 정식 배포 (Azure)

경진대회 제출·시연용 배포 절차. 리소스 정의는 [azure/main.bicep](../azure/main.bicep), 실행은 [deploy/azure/deploy.sh](../deploy/azure/deploy.sh).

```
사용자 ─https─▶ Front Door(WAF) ─▶ scrap-web ─/api─▶ scrap-server ─▶ scrap-diagnosis, scrap-route
                                   (App Service 플랜 하나에 앱 4개)  └─▶ DB VM: PostgreSQL 17 (scrap_server, scrap_engine)
```

모든 리소스는 **Korea Central**(Front Door는 전역), 리소스 그룹은 받은 그룹 `TEAM_AIBIC2026_01_RG_EUS2`(이름만 EUS2).

## 구독 제한에 맞춘 구성

부트캠프 구독은 리소스 그룹 **기여자** 권한만 있고, 쓸 수 있는 서비스·지역이 제한돼 있음.

| 제한 | 구성 |
| --- | --- |
| Container Apps 미등록, 공급자 등록 권한 없음 | App Service(Linux, 컨테이너). 플랜 하나에 앱 4개 |
| App Service 할당량이 Korea Central에만 있음 | 전체를 Korea Central에 둠 |
| 관리형 PostgreSQL 생성 불가 (모든 지역·등급에서 SkuNotAvailable) | VNet 안의 DB VM에서 Docker로 PostgreSQL 17. 고정 사설 IP `10.0.2.4`, 공용 IP 없음, 앱 서브넷에서 오는 5432만 허용, VNet 안이라 TLS 없음 |
| 역할 할당 불가 | ACR 관리자 계정으로 이미지를 받고, Key Vault는 액세스 정책으로 앱용 관리 ID에 읽기 권한을 줌 |
| ACR Basic은 웹훅 2개까지 | ACR Standard |
| 새 VNet은 기본 인터넷 출구가 없음 | NAT 게이트웨이 (앱의 Azure OpenAI 호출, DB VM 이미지 받기) |
| Key Vault 완전 삭제(purge) 권한 없음 | 지운 Key Vault 이름은 7일간 다시 못 씀. 리소스 이름 뒤 고유 문자열에 지역을 넣어 피함 |

그 밖에
- 내부 앱(server·diagnosis·route)은 VNet(`snet-apps`)에서 오는 요청만, web은 Front Door를 거친 요청(`X-Azure-FDID`)만 받음
- main 배포: GitHub Actions가 ACR에 `:main`으로 push하면 ACR 웹훅이 App Service에 알려 새 이미지로 다시 시작

## 0. 준비

- 이 PC에 Azure CLI, Docker, Git
  ```powershell
  winget install Microsoft.AzureCLI
  az config set core.enable_broker_on_windows=false   # Windows 로그인 창 오류가 날 때
  az login --tenant soldeskms.onmicrosoft.com
  ```
- `scrap-infra/.env`에 Azure OpenAI 값과 Mapbox 토큰 (로컬 실행용과 같은 값)
- (선택) 시험성적서 스캔본·사진 OCR: `DIAGNOSIS_ALLOW_DOCUMENT_OCR=true`, `DIAGNOSIS_AZURE_DOCINTEL_ENDPOINT`, `DIAGNOSIS_AZURE_DOCINTEL_API_KEY`. 키는 `secrets` 단계에서 Key Vault `diagnosis-docintel-key`로 들어가고, 켜기·주소는 `core`/`apps` 단계 앱 설정으로 들어감. Key Vault에 실제 키가 없으면(처음 자리값 `unset` 포함) 경고를 내고 OCR을 끈 채 배포하므로, 키를 넣은 뒤 `secrets` → `apps` 순서로 다시 실행함. OCR 결과 대기는 `diagnosisOcrTimeoutSeconds`(기본 120초)이고, 업로드도 server 대기(`diagnosisEngineTimeoutSeconds`, 기본 200초) 안에 끝나야 해서 그보다 작게 둠. 문서 이미지가 Azure로 전송되고 쪽마다 과금. 글자 층이 있는 PDF는 OCR 없이도 읽음
- (선택) 카카오 REST 키 `KAKAO_MOBILITY_REST_API_KEY`: 있으면 server가 사업장 주소 검색에 Kakao Local, 처리업체까지 도로 거리에 Kakao Mobility를 씀. 없으면 주소 검색은 공개 Photon으로 대신하고 도로 거리는 나오지 않음. `secrets` 단계에서 Key Vault `kakao-rest-api-key`로 들어감(`.env` 값이 없으면 server 앱 설정에 직접 넣어 둔 값을 옮김). Key Vault에 키가 있을 때만 `apps` 단계가 server 설정에 Key Vault 참조로 넣음. server 앱 설정에만 키가 있고 Key Vault에 없으면 `apps`가 멈춤(그대로 배포하면 키가 지워지므로 `secrets`를 먼저 실행)
- DB VM 관리용 SSH 공개 키 `~/.ssh/scrap_key.pub` (다른 키는 `DB_SSH_KEY=<경로>`)
- 레포 다섯 개를 형제 폴더로 둠 (`scrap-web`, `scrap-server`, `scrap-diagnosis`, `scrap-route`, `scrap-infra`)

## 1. 리소스 만들기

Git Bash에서 `scrap-infra` 폴더 기준으로 실행함.

```bash
ALERT_EMAIL=<경고 받을 메일> deploy/azure/deploy.sh core      # 네트워크·DB VM·Key Vault·ACR 등
deploy/azure/deploy.sh secrets                                 # Key Vault 비밀값 (이미 있는 값은 그대로)
ALERT_EMAIL=<경고 받을 메일> deploy/azure/deploy.sh apps      # App Service 앱 4개, 배포 웹훅, Front Door/WAF
```

| 단계 | 만드는 것 |
| --- | --- |
| core | VNet(`snet-apps`, `snet-db`), NAT 게이트웨이, DB VM(PostgreSQL 17, DB 2개는 첫 부팅 때 생성), Key Vault, ACR, 앱용 관리 ID, Log Analytics, Application Insights, DB VM CPU 경고 |
| secrets | JWT·세션 비밀값, 서비스 토큰 2개, DB 주소 2개, OpenAI 키 2개, 소셜 로그인 비밀값 자리(`unset`), 카카오 REST 키(있을 때만) |
| apps | App Service 플랜(B2)과 앱 4개, ACR 웹훅 4개, Front Door와 WAF(IP당 분당 요청 수 제한), server 5xx 경고 |

- 비밀값은 화면에 출력하지 않음. DB 비밀번호는 Key Vault `postgres-admin-password`에만 있음
- `apps` 출력의 `publicUrl`이 접속 주소. Front Door 반영에 10~30분 걸림
- 다시 실행해도 됨. 바뀐 부분만 반영됨
- 이미지는 main 병합 때 GitHub Actions가 올림. 앱이 이미지 없이 먼저 만들어져도 괜찮음(이미지가 올라오면 웹훅으로 시작)
- 급할 때는 이 PC에서 직접 올릴 수 있음: `BRANCH=main deploy/azure/deploy.sh images`

## 2. GitHub Actions (main에 병합하면 배포)

각 레포의 `.github/workflows/deploy-azure.yml`이 main push 때 이미지를 빌드해 ACR에 `:main`과 커밋 태그로 올림. 실패하면 Discord로 알림.

레포 4개의 Settings → Secrets and variables → Actions에 넣음.

| 종류 | 이름 | 값 |
| --- | --- | --- |
| Variable | `ACR_LOGIN_SERVER` | `az acr show -n <acr> --query loginServer -o tsv` |
| Variable | `ACR_USERNAME` | `az acr credential show -n <acr> --query username -o tsv` |
| Secret | `ACR_PASSWORD` | `az acr credential show -n <acr> --query "passwords[0].value" -o tsv \| Set-Clipboard` |
| Secret | `DISCORD_WEBHOOK_URL` | Discord 채널 → 연동 → 웹후크 |
| Secret (scrap-web만) | `VITE_MAPBOX_ACCESS_TOKEN` | 지도 토큰 |
| Secret (scrap-web만, 선택) | `VITE_KAKAO_MAP_APP_KEY` | 카카오 지도 JavaScript 키(REST 키 아님). 카카오 앱에 `https://app.scrap-ai.org` 도메인 등록 필요 |

## 3. 데이터 (처음 한 번, 참조 데이터가 바뀌면 다시)

```bash
deploy/azure/deploy.sh seed     # 엔진 DB 마이그레이션 + 공정 참조 데이터 적재 (이미지가 ACR에 올라간 뒤)
```

DB VM에서 ACR 이미지(`:main`)를 한 번씩 실행함.
- scrap-diagnosis: `alembic upgrade head` (엔진 DB). **diagnosis에 DB 변경이 들어간 main 배포 뒤에는 다시 실행해야 함**
- scrap-server: 마이그레이션 후 공정 참조 데이터 적재. 실행할 때마다 참조 데이터를 갈아끼움 (server는 시작할 때도 마이그레이션을 실행함)

App Service 컨테이너에는 SSH로 들어갈 수 없고, App Service 시작 명령은 따옴표를 풀지 않아 `sh -c "a && b"` 같은 명령이 문법 오류로 꺼짐. 그래서 diagnosis는 이미지 기본 명령(uvicorn)으로만 띄우고 마이그레이션은 여기서 실행함.

### 시연용 업체 연결 (발표 시연 동안만)

운영은 기본적으로 시연용(synthetic) 업체 연결을 막음. 기업 간 인계를 끝까지 보여 주려면 켜고, 발표가 끝나면 끔.

```bash
deploy/azure/deploy.sh demo on       # server 앱 설정 DEMO_FACILITY_BINDINGS=true (앱 재시작)
# 각 계정이 소셜 로그인 → 기업 등록까지 마친 뒤
deploy/azure/deploy.sh demo-bind b@회사.com jungang-gongju npc-chemical-hwaseong sarom-hwaseong-2
deploy/azure/deploy.sh demo-bind c@회사.com veolia-doksan-hwaseong bgf-yesan bgf-hwaseong veolia-dspl-hwaseong
deploy/azure/deploy.sh demo off      # 발표 후
```

- 업체 키 예시는 scrap-server `app/domains/transport/dev_accounts.py`의 `DEFAULT_BINDINGS` (PP 선별·파쇄, PP 펠렛, 알루미늄캔)
- 화면에는 "시연용 계정"으로 표시됨. 실제 반입 승인 근거가 아님
- `apps`를 다시 실행해도 지금 값을 유지함 (`DEMO_FACILITY_BINDINGS=false`로 넘기면 끔)

### 처리업체(B·C) 로그인 계정

인계를 받는 처리업체는 회원가입 없이 공정표 업체마다 발급한 아이디·비밀번호로 로그인함 (scrap-server `docs/specs/facility-password-login.md`). server 이미지가 main에 올라간 뒤 실행함.

```bash
deploy/azure/deploy.sh facility-accounts           # 업체 전체 발급. 아이디 = 업체 키 (예: sarom-hwaseong-2)
deploy/azure/deploy.sh facility-password           # 공통 비밀번호 보기 (Key Vault facility-login-password)
deploy/azure/deploy.sh facility-accounts --force   # demo-bind 등으로 다른 계정에 연결된 업체도 옮김
```

- 연결은 synthetic이 아니라서 `demo on` 없이도 수신 업체로 보임
- 다시 실행해도 계정이 늘지 않음. Key Vault 비밀번호를 바꾼 뒤 실행하면 전체 비밀번호가 바뀜

## 4. 도메인과 소셜 로그인

하위 도메인(예: `app.<도메인>`)을 씀. 루트 도메인은 CNAME을 걸 수 없어 Front Door 연결이 번거로움.

1. `CUSTOM_HOST=app.<도메인> deploy/azure/deploy.sh apps` → Front Door에 사용자 지정 도메인과 Azure 관리 인증서가 붙고, 출력에 `customDomainValidationToken`이 나옴
2. 도메인 DNS에 두 레코드를 넣음. 확인되면 인증서가 자동 발급됨 (몇 분~몇 시간)
   | 종류 | 이름 | 값 |
   | --- | --- | --- |
   | TXT | `_dnsauth.app` | `customDomainValidationToken` |
   | CNAME | `app` | `frontDoorHost` |
3. Google·Microsoft OAuth 앱 리디렉션 주소: `https://app.<도메인>/api/v1/auth/google/callback`, `https://app.<도메인>/api/v1/auth/microsoft/callback`
4. 비밀값과 앱 설정 반영
   ```bash
   az keyvault secret set --vault-name <kv 이름> -n google-client-secret --value '<값>' -o none
   az keyvault secret set --vault-name <kv 이름> -n microsoft-client-secret --value '<값>' -o none
   CUSTOM_HOST=app.<도메인> GOOGLE_CLIENT_ID=<id> MICROSOFT_CLIENT_ID=<id> deploy/azure/deploy.sh apps
   ```
   Key Vault 값만 바꾼 경우 앱을 다시 시작해야 새 값을 읽음 (`az webapp restart`)

prod라 개발용 로그인은 꺼져 있음. 소셜 로그인을 설정하기 전에는 로그인할 수 없음.

## 5. 확인

- [ ] `publicUrl`로 HTTPS 접속, http는 https로 넘어감
- [ ] web·server·diagnosis·route 앱 주소로 직접 들어오면 403
- [ ] 소셜 로그인, 새로고침해도 로그인 유지
- [ ] 문진 자유 답변(Azure OpenAI), 처리 경로 업체 검토·웹 조사
- [ ] 기업 간 인계와 폰 QR 입고
- [ ] Log Analytics에 앱 로그가 쌓임

## 자주 쓰는 명령

`RG=TEAM_AIBIC2026_01_RG_EUS2`, 앱 이름은 `apps` 출력이나 포털에서 확인 (`scrap-server-<고유 문자열>`).

| 하려는 일 | 명령 |
| --- | --- |
| 앱 로그 보기 | `az webapp log tail -g $RG -n <앱 이름>` |
| 앱 재시작 | `az webapp restart -g $RG -n <앱 이름>` |
| 이전 이미지로 되돌리기 | `az webapp config container set -g $RG -n <앱 이름> --container-image-name <acr>/<레포>:<커밋 태그>` |
| DB 상태 | `az vm run-command invoke -g $RG -n vm-scrap-db --command-id RunShellScript --scripts "docker ps"` |
| 비용 멈추기 | App Service 플랜을 B1로 낮추거나 지움, DB VM 할당 취소(`az vm deallocate -g $RG -n vm-scrap-db`) |

DB VM은 자동 백업이 없음. 시연 데이터를 지켜야 하면 `docker exec postgres pg_dumpall`로 덤프를 떠 둠.
