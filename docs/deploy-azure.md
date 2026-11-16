# 정식 배포 (Azure)

경진대회 제출·시연용 배포 절차. 리소스 정의는 [azure/main.bicep](../azure/main.bicep), 실행은 [deploy/azure/deploy.sh](../deploy/azure/deploy.sh).

```
사용자 ─https─▶ Front Door(WAF) ─▶ scrap-web ─/api─▶ scrap-server ─▶ scrap-diagnosis, scrap-route
                                   (App Service 플랜 하나에 앱 4개)  └─▶ PostgreSQL 17 (scrap_server, scrap_engine)
```

## 구독 권한에 맞춘 구성

부트캠프 구독은 받은 리소스 그룹(`TEAM_AIBIC2026_01_RG_EUS2`)의 **기여자** 권한만 있음. 리소스 그룹 만들기, 역할 할당, 리소스 공급자 등록(Container Apps)을 할 수 없어 아래처럼 구성함.

| 필요한 것 | 방법 |
| --- | --- |
| 앱 실행 | App Service(Linux, 컨테이너). 플랜 하나에 앱 4개 |
| 이미지 가져오기 | ACR 관리자 계정 |
| 비밀값 | Key Vault 액세스 정책에 앱용 관리 ID를 넣고 앱 설정에서 Key Vault 참조 |
| 내부 앱 보호 | server·diagnosis·route는 VNet(`snet-apps`)에서 오는 요청만 받음 |
| Front Door 우회 차단 | web은 Front Door 서비스 태그와 `X-Azure-FDID` 헤더가 맞는 요청만 받음 |
| main 배포 | GitHub Actions가 ACR에 `:main`으로 push하면 ACR 웹훅이 App Service에 알려 새 이미지로 다시 시작 |

## 0. 준비

- 이 PC에 Azure CLI, Docker, Git
  ```powershell
  winget install Microsoft.AzureCLI
  az config set core.enable_broker_on_windows=false   # Windows 로그인 창 오류가 날 때
  az login --tenant soldeskms.onmicrosoft.com
  ```
- `scrap-infra/.env`에 Azure OpenAI 값과 Mapbox 토큰 (로컬 실행용과 같은 값)
- 레포 다섯 개를 형제 폴더로 둠 (`scrap-web`, `scrap-server`, `scrap-diagnosis`, `scrap-route`, `scrap-infra`)

## 1. 리소스 만들기

Git Bash에서 `scrap-infra` 폴더 기준으로 실행함.

```bash
ALERT_EMAIL=<경고 받을 메일> deploy/azure/deploy.sh core      # 10~15분 (PostgreSQL이 가장 오래 걸림)
deploy/azure/deploy.sh secrets                                 # Key Vault 비밀값 (이미 있는 값은 그대로)
BRANCH=main deploy/azure/deploy.sh images                      # 4개 레포 main을 빌드해 ACR에 :main으로 올림
ALERT_EMAIL=<경고 받을 메일> deploy/azure/deploy.sh apps      # App Service 앱 4개, 배포 웹훅, Front Door/WAF
```

| 단계 | 만드는 것 |
| --- | --- |
| core | VNet(`snet-apps`, `snet-db`), PostgreSQL 17과 DB 2개, Key Vault, ACR, 앱용 관리 ID, Log Analytics, Application Insights, DB CPU 경고 |
| secrets | JWT·세션 비밀값, 서비스 토큰 2개, DB 주소 2개, OpenAI 키 2개, 소셜 로그인 비밀값 자리(`unset`) |
| images | 4개 이미지 (git 브랜치 내용만 빌드, 로컬 작업 파일은 안 들어감). `:main`과 커밋 태그 |
| apps | App Service 플랜과 앱 4개, ACR 웹훅 4개, Front Door와 WAF(IP당 분당 요청 수 제한), server 5xx 경고 |

- 비밀값은 화면에 출력하지 않음. DB 비밀번호는 Key Vault `postgres-admin-password`에만 있음
- `apps` 출력의 `publicUrl`이 접속 주소. Front Door 반영에 10~30분 걸릴 수 있음
- 다시 실행해도 됨. 바뀐 부분만 반영됨
- 앱이 만들어진 뒤에는 `images`만 다시 실행해도 웹훅으로 새 이미지가 배포됨

## 2. GitHub Actions (main에 병합하면 배포)

각 레포의 `.github/workflows/deploy-azure.yml`이 main push 때 이미지를 빌드해 ACR에 `:main`과 커밋 태그로 올림. 실패하면 Discord로 알림.

레포 4개의 Settings → Secrets and variables → Actions에 넣음.

| 종류 | 이름 | 값 |
| --- | --- | --- |
| Variable | `ACR_LOGIN_SERVER` | `az acr show -n <acr> --query loginServer -o tsv` |
| Variable | `ACR_USERNAME` | 포털 ACR → 액세스 키의 사용자 이름 |
| Secret | `ACR_PASSWORD` | 포털 ACR → 액세스 키의 password |
| Secret | `DISCORD_WEBHOOK_URL` | Discord 채널 웹훅 주소 |
| Secret (scrap-web만) | `VITE_MAPBOX_ACCESS_TOKEN` | 지도 토큰 |

## 3. 도메인과 소셜 로그인

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

## 4. 데이터 (처음 한 번, 참조 데이터가 바뀌면 다시)

server 컨테이너에 SSH로 들어가 실행함 (포털 → scrap-server 앱 → SSH, 또는 `az webapp ssh`).

```bash
python -m app.domains.treatment.import_catalog          # 공정 참조 데이터
python -m app.domains.transport.dev_accounts            # 시연용 업체 연결 (server의 prod 연결 기능이 병합된 뒤)
```

## 5. 확인

- [ ] `publicUrl`로 HTTPS 접속, http는 https로 넘어감
- [ ] web 앱 주소(`webHost`)로 직접 들어오면 403
- [ ] server·diagnosis·route 주소로 직접 들어오면 403
- [ ] 소셜 로그인, 새로고침해도 로그인 유지
- [ ] 문진 자유 답변(Azure OpenAI), 처리 경로 업체 검토·웹 조사
- [ ] 기업 간 인계와 폰 QR 입고
- [ ] Log Analytics에 앱 로그가 쌓임

## 자주 쓰는 명령

`RG=TEAM_AIBIC2026_01_RG_EUS2`, 앱 이름은 `apps` 출력이나 포털에서 확인 (`scrap-server-<고유 문자열>`).

| 하려는 일 | 명령 |
| --- | --- |
| 로그 보기 | `az webapp log tail -g $RG -n <앱 이름>` |
| 재시작 | `az webapp restart -g $RG -n <앱 이름>` |
| 이전 이미지로 되돌리기 | `az webapp config container set -g $RG -n <앱 이름> --container-image-name <acr>/<레포>:<커밋 태그>` |
| 비용 멈추기 | App Service 플랜을 지우거나 B1로 낮춤, PostgreSQL 중지(`az postgres flexible-server stop`) |
