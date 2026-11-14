#!/usr/bin/env bash
# 단일 VM 시험 배포 갱신: 모든 레포를 main 최신으로 받고 바뀐 서비스만 다시 빌드한다.
# GitHub Actions(deploy-vm)가 SSH로 이 스크립트만 실행한다(authorized_keys의 command=).
# 직접 실행해도 된다: ~/scrap/scrap-infra/deploy/update.sh
#
# 실행 중에 git pull로 이 파일이 바뀌어도 안전하도록 전체를 함수로 읽은 뒤 실행한다.

main() {
	set -euo pipefail
	local root repos
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	repos=(scrap-web scrap-server scrap-diagnosis scrap-route scrap-infra)

	# 여러 레포에서 동시에 main이 올라와도 한 번에 하나씩 배포한다
	exec 9>/tmp/scrap-deploy.lock
	flock 9

	echo "== $(date -u +%FT%TZ) 배포 시작"
	for r in "${repos[@]}"; do
		git -C "$root/$r" pull --ff-only --quiet origin main
		echo "$r $(git -C "$root/$r" log -1 --format='%h %s')"
	done

	cd "$root/scrap-infra"
	docker compose up -d --build --remove-orphans
	docker image prune -f >/dev/null
	docker compose ps --format 'table {{.Service}}\t{{.Status}}'
	echo "== 배포 끝"
}

main "$@"
