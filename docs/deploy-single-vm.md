# 단일 VM 시험 배포

팀 내부 시험용으로 Azure VM 한 대에 전체 서비스를 띄우는 절차. 운영 배포가 아님.

- 바깥에는 caddy(80·443)만 열림. caddy가 HTTPS 인증서를 자동으로 받고 사이트 전체에 팀 전용 비밀번호를 검
- 로그인은 개발용 로그인만 씀(이메일만 넣으면 그 계정으로 들어감). 그래서 팀 비밀번호 없이 열면 안 됨
- Google·Microsoft 로그인은 쓰지 않으므로 리디렉션 주소 등록이 필요 없음
- web·server·diagnosis·route·DB는 내부망으로만 통신함

```
브라우저 ─https─▶ caddy(팀 비밀번호) ─▶ web(nginx) ─/api─▶ server ─▶ diagnosis, route
                                                              └─▶ server-db
```

## 1. VM 준비 (Azure 포털)

| 항목 | 값 |
| --- | --- |
| 이미지 | Ubuntu Server 24.04 LTS x64 Gen2 |
| 크기 | `Standard_D4s_v5` (4 vCPU / 16GB). 할당량이 없으면 `D4as_v5`, `B4ms` |
| 디스크 | 64GB 이상 |
| 지역 | Korea Central |
| 인증 | SSH 키 (사용자 `azureuser`) |
| 인바운드 포트 | 22, 80, 443 (22는 가능하면 내 IP로만) |
| 공용 IP | DNS 이름 레이블 설정 (예: `scrap-test` → `scrap-test.koreacentral.cloudapp.azure.com`) |

GPU 크기(NV·NC 계열)는 필요 없음.

## 2. Docker 설치 (VM에서)

```bash
ssh -i <키.pem> azureuser@<DNS 이름>

curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
exit   # 다시 접속해야 docker 그룹이 적용됨
```

다시 접속한 뒤 `docker compose version`이 2.24 이상인지 확인함(`!reset` 문법 사용).

## 3. 레포 받기

로컬 폴더 구성과 같게 형제 폴더로 clone함. 비공개 레포(scrap-server, scrap-diagnosis, scrap-infra)는 레포마다 읽기 전용 배포 키를 VM에 만들어 받음(GitHub는 배포 키 하나를 여러 레포에 쓸 수 없음).

```bash
# 비공개 레포마다 키 만들기
for r in scrap-server scrap-diagnosis scrap-infra; do
  ssh-keygen -q -t ed25519 -N "" -C "vm-deploy-$r" -f ~/.ssh/deploy_$r
  printf "Host github-%s\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/deploy_%s\n  IdentitiesOnly yes\n\n" $r $r >> ~/.ssh/config
  cat ~/.ssh/deploy_$r.pub   # 레포 Settings → Deploy keys → Add (쓰기 권한 없이)
done
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts

mkdir -p ~/scrap && cd ~/scrap
git clone -b main https://github.com/BluberrypAI/scrap-web.git
git clone -b main https://github.com/BluberrypAI/scrap-route.git
git clone -b main git@github-scrap-server:BluberrypAI/scrap-server.git
git clone -b main git@github-scrap-diagnosis:BluberrypAI/scrap-diagnosis.git
git clone -b main git@github-scrap-infra:BluberrypAI/scrap-infra.git
cd scrap-infra
```

배포는 각 레포의 `main`을 받음. 올릴 변경은 develop → main으로 병합해 둠. 다른 브랜치를 시험할 때는 `-b <브랜치>`만 바꿈.

## 4. .env 작성

```bash
cp .env.example .env
nano .env
```

| 값 | 넣을 것 |
| --- | --- |
| `COMPOSE_FILE` | `compose.yaml:compose.deploy.yaml` (주석 해제) |
| `SITE_ADDRESS` | DNS 이름 (예: `scrap-test.koreacentral.cloudapp.azure.com`) |
| `BASIC_AUTH_USER` | 팀 비밀번호 사용자명 |
| `BASIC_AUTH_HASH` | 아래 명령으로 만든 해시를 **작은따옴표**로 감싸 넣음 |
| `ENGINE_SERVICE_TOKEN`, `SCRAP_INTAKE_SERVICE_TOKEN`, `JWT_SECRET`, `SESSION_SECRET` | 각각 `openssl rand -hex 24`로 새로 만듦 |
| `DIAGNOSIS_AZURE_OPENAI_*`, `ROUTE_AZURE_OPENAI_*` | Azure OpenAI 값 |
| `VITE_MAPBOX_ACCESS_TOKEN` | 지도 토큰 (없으면 지도만 안 나옴) |

`BACKEND_URL`, `FRONTEND_URL`, `SERVER_APP_ENV`, `VITE_ENABLE_DEV_LOGIN`, `*_PORT`는 배포 덮어쓰기가 정하므로 두어도 됨.

```bash
# 팀 비밀번호 해시 만들기 (비밀번호는 셸 기록에 남지 않게 앞에 공백을 두거나 끝나고 history -c)
docker run --rm caddy:2.8 caddy hash-password --plaintext '<팀 비밀번호>'
# 출력 예: $2a$14$....  → .env에 BASIC_AUTH_HASH='$2a$14$....'

chmod 600 .env
```

## 5. 빌드·실행

```bash
docker compose config --quiet && echo OK   # .env 값 확인
docker compose up -d --build                # 처음엔 빌드에 몇 분 걸림
docker compose run --rm server-seed         # 처음 한 번: 처리 경로 공정 참조 데이터 적재
docker compose ps
```

`https://<DNS 이름>`을 열면 팀 비밀번호 창이 뜸. 인증서는 처음 접속 전 caddy가 받아 둠(`docker compose logs caddy`에서 `certificate obtained` 확인).

## 6. 시험 계정 연결 (기업 간 인계)

인계 흐름은 업체에 수신 기업 계정이 연결돼 있어야 인수 요청을 보낼 수 있음.

1. 웹의 개발용 로그인으로 아래 이메일에 각각 들어가 기업 등록까지 마침
   - `pp-sort@example.com` (PP·PE 선별·파쇄)
   - `pp-pellet@example.com` (PP·PE 펠렛·컴파운드)
   - `al-can@example.com` (알루미늄캔 판재·잉곳)
2. VM에서 연결 실행

```bash
docker compose exec server python -m app.domains.transport.dev_accounts
```

`연결 ... -> 기업명`이 업체 수만큼 나오면 됨. `건너뜀`이 나오면 해당 이메일의 기업 등록을 먼저 함.

## 7. 배포 후 확인

- [ ] `http://<DNS 이름>` → `https`로 넘어가고 팀 비밀번호 창이 뜸
- [ ] 비밀번호 없이(취소) 열면 401
- [ ] 개발용 로그인으로 로그인되고 새로고침해도 유지됨
- [ ] 문진에서 자유 문장 답변이 처리됨 (Azure OpenAI 연결)
- [ ] PE 필름: 선별·파쇄 → 펠렛·컴파운드 인계, 수신 계정에서 입고 기록
- [ ] 알루미늄캔: 판재·잉곳 업체 인계, 수신 계정에서 입고 기록
- [ ] `docker compose ps`에서 web·server·diagnosis·route 외부 포트가 없음

## 8. 업데이트·재시작

```bash
cd ~/scrap
for d in scrap-web scrap-server scrap-diagnosis scrap-route scrap-infra; do git -C $d pull --ff-only; done
cd scrap-infra
docker compose up -d --build        # 바뀐 서비스만 다시 빌드됨
docker compose up -d --build web    # 한 서비스만
docker image prune -f               # 이전 이미지 정리 (디스크 확보)
```

| 하려는 일 | 명령 |
| --- | --- |
| 로그 | `docker compose logs -f server` |
| 재시작 | `docker compose restart server` |
| 중지 (데이터 유지) | `docker compose down` |
| DB까지 초기화 | `docker compose down -v` 후 5·6번 다시 |
| 팀 비밀번호 변경 | 해시를 새로 만들어 `.env`에 넣고 `docker compose up -d caddy` |

VM을 재부팅해도 컨테이너는 자동으로 다시 뜸.

## 9. main에 올리면 자동 배포

각 레포의 `.github/workflows/deploy-vm.yml`이 main push 때 VM에 SSH로 접속함. 이 키는 VM `authorized_keys`에 `restrict,command=".../deploy/update.sh"`로 등록해 배포 스크립트만 실행됨(셸 접속 불가). `update.sh`는 5개 레포를 모두 main 최신으로 받고 `docker compose up -d --build`를 실행함. 여러 레포가 동시에 올라와도 VM에서 하나씩 처리함.

```bash
# 이 PC에서 배포 전용 키 만들기
ssh-keygen -q -t ed25519 -N "" -C github-actions-deploy -f ~/.ssh/scrap_actions_deploy
# VM에 등록 (한 줄)
echo "restrict,command=\"/home/azureuser/scrap/scrap-infra/deploy/update.sh\" $(cat ~/.ssh/scrap_actions_deploy.pub)" \
  | ssh azureuser@<DNS 이름> 'cat >> ~/.ssh/authorized_keys'
# VM 호스트 키 (VM_KNOWN_HOSTS 값)
ssh-keyscan -t ed25519 <DNS 이름>
```

5개 레포 각각 Settings → Secrets and variables → Actions에 넣음.

| 종류 | 이름 | 값 |
| --- | --- | --- |
| Secret | `VM_DEPLOY_SSH_KEY` | `~/.ssh/scrap_actions_deploy` 파일 내용 전체 |
| Variable | `VM_HOST` | DNS 이름 |
| Variable | `VM_USER` | `azureuser` |
| Variable | `VM_KNOWN_HOSTS` | `ssh-keyscan` 결과 한 줄 |

`VM_HOST`가 없는 레포는 배포 작업을 건너뜀. 수동 실행은 Actions → Deploy VM → Run workflow.
`server-seed`(공정 참조 데이터)는 자동 배포에 넣지 않았음. 데이터가 바뀌면 `docker compose run --rm server-seed`를 직접 실행함.

## 주의

- 개발용 로그인이 켜져 있으므로 **caddy 비밀번호를 끄거나 web 포트를 직접 열면 안 됨**
- DB 비밀번호는 로컬 기본값이지만 DB 포트를 바깥에 열지 않으므로 시험용으로는 그대로 둠. 실제 데이터를 넣는 배포로 바꿀 때는 DB 비밀번호·`APP_ENV=prod`·소셜 로그인으로 다시 구성함
- `.env`와 Azure OpenAI 키는 VM에만 둠. 대화·이슈에 붙이지 않음
- 시험이 끝나면 VM을 **중지(할당 취소)**해야 요금이 멈춤
