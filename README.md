# scrap-infra

SCRAP의 **infra** 레포. 전체 통합 실행 compose, Azure 리소스 정의(Bicep), 함께 배포할 버전 조합 기록을 담당함.

- 하지 않는 일: 서비스 코드
- 팀 공통 규칙: 조직 `.github` 레포의 [CONTRIBUTING.md](https://github.com/BluberrypAI/.github/blob/main/CONTRIBUTING.md)

## 로컬 폴더 구성

다른 레포를 이 레포 **안이 아니라 옆에** clone함. 통합 compose는 형제 폴더를 빌드 경로로 사용함.
폴더 이름이 다르면 `.env`의 `*_DIR`을 바꿈.

```
resource-ai/
├─ scrap-web/         # 화면
├─ scrap-server/      # API, 인증, 기업 정보
├─ scrap-diagnosis/   # 문진 엔진
├─ scrap-route/       # 처리 경로 AI
└─ scrap-infra/       # 이 레포
```

## 전체 서비스 로컬 실행

Docker Desktop만 있으면 됨. 배포와 같은 빌드 이미지로 띄움(코드를 고치면 `--build`로 다시 빌드).

```bash
cp .env.example .env              # 토큰·키 값 채우기 (아래 표)
docker compose up -d --build      # 전체 빌드·실행
docker compose run --rm server-seed   # 처음 한 번: 처리 경로 공정 참조 데이터 적재
```

브라우저에서 **http://localhost:5178** 을 염 (`127.0.0.1`이 아니라 `localhost`, 소셜 로그인 쿠키 때문).
`VITE_ENABLE_DEV_LOGIN=true`면 로그인 화면의 "개발용 로그인"으로 OAuth 키 없이 들어갈 수 있음.

| 서비스 | 레포 | 주소 | 비고 |
| --- | --- | --- | --- |
| web | scrap-web | http://localhost:5178 | nginx. `/api`를 server로 전달 |
| server | scrap-server | http://localhost:8000/docs | 시작할 때 마이그레이션 자동 적용 |
| diagnosis | scrap-diagnosis | http://localhost:8030/docs | 확인용. server는 내부망으로 부름 |
| route | scrap-route | http://localhost:8010/docs | 확인용. server는 내부망으로 부름 |
| server-db, diagnosis-db | - | 내부망 전용 | 데이터는 Docker 볼륨에 남음 |

호출 관계: `web → server → diagnosis(문진), route(업체 검토·웹 조사)`. 브라우저는 web만 부름.

### .env에 채울 값

| 값 | 없으면 |
| --- | --- |
| `ENGINE_SERVICE_TOKEN`, `SCRAP_INTAKE_SERVICE_TOKEN` | 로컬 기본값으로 동작. 영문·숫자만 사용 (한글이 섞이면 server 요청이 500) |
| `DIAGNOSIS_AZURE_OPENAI_*` | 문진이 자유 문장을 못 알아듣고 선택지 버튼으로만 진행 (`DIAGNOSIS_LLM_PROVIDER=off`와 같음) |
| `ROUTE_AZURE_OPENAI_*` | 처리 경로의 업체 검토·웹 조사가 "미완료"로 남아 인수 요청을 보낼 수 없음 |
| `VITE_MAPBOX_ACCESS_TOKEN` | 처리 경로 지도가 안 나옴 (목록은 보임) |
| `GOOGLE_*`, `MICROSOFT_*` | 소셜 로그인 불가. 개발용 로그인은 가능 |

### 자주 쓰는 명령

```bash
docker compose ps                        # 상태
docker compose logs -f server            # 로그
docker compose up -d --build web         # 한 서비스만 다시 빌드
docker compose down                      # 중지 (데이터 유지)
docker compose down -v                   # 중지 + DB 데이터 삭제
```

### 처리 경로 데이터

`server-seed`는 실행할 때마다 공정 참조 데이터를 **갈아끼움**. 전국 명부까지 넣으려면 명부 JSON을 `data/`(또는 `REGISTRY_DIR`)에 두고 함께 넣음.

```bash
docker compose run --rm server-seed sh -c "alembic upgrade head && python -m app.domains.treatment.import_catalog --registry /registry/<파일명>.json --sha256 <SHA-256>"
```

명부 원본과 SHA-256은 scrap-server `backend/README.md`의 "SCRAP 처리경로와 전국 명부" 참고.

### 넣지 않은 것

scrap-route의 Neo4j(지식그래프 `/kg/*`)와 pgvector(법령 검색 `/rag/*`)는 띄우지 않음.
지금 server가 부르는 scrap-route API(`/treatment/intake-reviews`, `/treatment/facility-web-search`)는 둘 다 쓰지 않음.
server가 이 API를 쓰기 시작하면 compose에 추가함.

## 단일 VM 시험 배포

팀 내부 시험용으로 VM 한 대에 띄우는 절차는 [docs/deploy-single-vm.md](docs/deploy-single-vm.md) 참고.
`compose.deploy.yaml`을 겹쳐 써서 caddy(HTTPS·팀 비밀번호)만 바깥에 열고 개발용 로그인을 켬.

## 브랜치

작업 브랜치 → `develop` (PR, CI 통과 후 작성자가 병합) → `main` (배포, 서버 담당자)
