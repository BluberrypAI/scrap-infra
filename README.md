# Re_infra

Re:Source AI의 **infra** 레포. 전체 통합 실행 compose, Azure 리소스 정의(Bicep), 함께 배포할 버전 조합 기록을 담당함.

- 하지 않는 일: 서비스 코드
- 팀 공통 규칙: 조직 `.github` 레포의 [CONTRIBUTING.md](https://github.com/resource-ai-team/.github/blob/main/CONTRIBUTING.md)

## 로컬 폴더 구성

다른 레포를 이 레포 **안이 아니라 옆에** clone함. 통합 compose는 형제 폴더를 빌드 경로로 사용함.

```
resource-ai/
├─ server/     # Re_server
├─ ai/         # Re_AI
├─ frontend/   # Re_client
└─ infra/      # 이 레포
```

## 브랜치

작업 브랜치 → `develop` (PR, CI 통과 후 작성자가 병합) → `main` (배포, 서버 담당자)

## 실행

통합 compose가 추가되면 작성함.
