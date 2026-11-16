#!/usr/bin/env bash
# 단일 VM 시험 배포 갱신: 5개 레포를 지정한 브랜치 최신으로 맞추고 바뀐 서비스만 다시 빌드한다.
# 자동 배포는 하지 않는다. 필요할 때만 실행한다.
#   - GitHub: scrap-infra Actions → Deploy VM → Run workflow (브랜치 선택)
#     Actions 키는 authorized_keys의 command=로 이 스크립트만 실행하고, 고른 브랜치는 SSH_ORIGINAL_COMMAND로 들어온다
#   - VM에서 직접: ~/scrap/scrap-infra/deploy/update.sh [develop|main]
#
# 실행 중에 이 파일이 바뀌어도 안전하도록 전체를 함수로 읽은 뒤 실행한다.

main() {
	set -euo pipefail
	local root branch repos
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	repos=(scrap-web scrap-server scrap-diagnosis scrap-route scrap-infra)
	branch="${1:-${SSH_ORIGINAL_COMMAND:-develop}}"

	# 원격에서 들어온 값은 정해진 브랜치만 받는다
	case "$branch" in
		develop | main) ;;
		*) echo "브랜치는 develop 또는 main만 가능: $branch" >&2; exit 2 ;;
	esac

	# 동시에 두 번 실행되면 하나씩 처리한다
	exec 9>/tmp/scrap-deploy.lock
	flock 9

	echo "== $(date -u +%FT%TZ) $branch 배포 시작"
	for r in "${repos[@]}"; do
		git -C "$root/$r" fetch --quiet origin "$branch"
		# VM은 배포 전용이므로 로컬 브랜치를 원격과 똑같이 맞춘다
		git -C "$root/$r" checkout --quiet -B "$branch" "origin/$branch"
		echo "$r $(git -C "$root/$r" log -1 --format='%h %s')"
	done

	cd "$root/scrap-infra"
	docker compose up -d --build --remove-orphans
	docker image prune -f >/dev/null
	docker compose ps --format 'table {{.Service}}\t{{.Status}}'
	echo "== 배포 끝"
}

main "$@"
