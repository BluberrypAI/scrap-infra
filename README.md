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
| `VITE_MAPBOX_ACCESS_TOKEN` | 최신 web의 업체 지도는 MapLibre·OpenStreetMap 대체 표시 사용. 길찾기 키와 별개 |
| `KAKAO_MOBILITY_REST_API_KEY` | 도로거리 조회를 하지 않으며 직선거리·도로거리 미확인으로 표시 |
| `GOOGLE_*`, `MICROSOFT_*` | 소셜 로그인 불가. 개발용 로그인은 가능 |

문진 모델의 응답을 기다리다가 server가 먼저 끊지 않도록 `DIAGNOSIS_LLM_TIMEOUT_SECONDS=60`, `DIAGNOSIS_ENGINE_TIMEOUT_SECONDS=300`을 기본으로 연결한다. **scrap-diagnosis의 SDK 중첩 재시도 제거 버전과 함께 사용한다.** 추출·응답 각 최대 2회에 60초를 적용한 대기 예산 240초에 규칙·DB 처리 여유를 둔 값이다. 모델 대기를 늘리면 서버 대기도 맞춰야 한다. 웹 nginx의 대기 기본값은 600초다. 실제 평균 응답시간이나 대규모 동시 부하를 보장하는 수치는 아니다.

server는 diagnosis의 `/health`가 성공한 후 시작한다. 규칙 로드·DB 준비가 끝나기 전에 첫 문진을 보내는 시작 순서 문제를 줄인다.

2026-11-17에 실제 확인한 코드 조합과 범위는 [로컬 로그인·PP E2E 검증](docs/local-e2e-20261117.md)에 정리했다.

### 자주 쓰는 명령

```bash
docker compose ps                        # 상태
docker compose logs -f server            # 로그
docker compose up -d --build --no-deps web # 실행 중인 의존 서비스를 유지하고 web만 다시 빌드
docker compose down                      # 중지 (데이터 유지)
docker compose down -v                   # 중지 + DB 데이터 삭제
```

### 선택: 도로거리로 업체 비교

`.env`의 `KAKAO_MOBILITY_REST_API_KEY`에 자동차 길찾기가 활성화된 카카오모빌리티 REST API 키를 넣고 `docker compose up -d --force-recreate --no-deps server`를 실행한다. 키는 서버만 사용한다. 기존 물량은 **다시 검토**해서 저장된 거리도 갱신한다.

현재 보유 기업 좌표에서 모든 후보 업체 좌표까지 조회한다. 도로거리가 확인된 업체끼리 가까운 최대 5곳을 지도에 표시하고, 미확인 업체도 목록과 AI 검토에 남긴다. 전부 조회되지 않으면 직선거리로 명확히 표시한다. 지도 표시 키와 길찾기 키는 별개다. 기본 자동차 경로이므로 화물차 통행 제한·운송 견적을 대신하지 않는다.

2026-11-17 로컬에는 유효한 길찾기 키가 없어 카카오 실제 거리값은 아직 검증하지 않았다. 연결 규격·정렬·오류 처리는 모의 응답 테스트로 확인했다.

### 공정·명부 적재

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
`compose.deploy.yaml`을 겹쳐 써서 caddy(HTTPS·팀 비밀번호)만 바깥에 열고 개발용 로그인을 켬. 배포는 Actions에서 수동 실행(자동 배포 없음).

## 브랜치

작업 브랜치 → `develop` (PR, CI 통과 후 작성자가 병합) → `main` (배포, 서버 담당자)

## 키 없이 도로거리 사용 (2026-11-17 후속)

로컬 `.env`에서 `OSRM_DEMO_ENABLED=true` 후 server를 재생성하면 카카오 키 없이 OSRM/FOSSGIS 자동차 경로를 조회한다. 기본값은 false. 실제 화성 시험 사업장에서 14개 후보 중 좌표 있는 9개 경로 응답을 받았다. 지도 상위 5곳: 새롬 16.2562km, NPC 18.8794km, 일신 43.8543km, 유원 43.9281km, 중일 44.7754km. 이는 해당 시험 좌표·당시 OSM 경로의 결과이며 실제 입구 위치·화물차 제한은 별도다.

공개 서버 이용 조건에 맞춰 단일 워커·초당 최대 1회, 전체 후보 40곳씩 묶음, 완전한 응답 24시간 메모리 캐시(최대256건)를 사용한다. 좌표 외 기업정보·사진은 전송하지 않는다. 도로에 붙인 위치가 원래 좌표에서 500m 넘으면 거리 미확인으로 둔다. 운영/다중 워커/대규모 트래픽에는 공개 서버를 그대로 쓰지 말고 자체 OSRM 또는 계약 경로 서버로 전환해야 한다.

OSRM은 최단시간 경로의 거리를 반환한다. 모든 가능한 길 중 최단거리·실시간 교통·실제 GPS 주행 기록이 아니다. 키 없는 공개 데모 옵션은 카카오 실패를 숨겨 대체하는 방식이 아니며 카카오 키가 있으면 카카오를 우선 사용한다.

출처: https://routing.openstreetmap.de/about.html / https://project-osrm.org/docs/v5.24.0/api/#table-service
