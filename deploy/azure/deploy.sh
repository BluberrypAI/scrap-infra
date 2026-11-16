#!/usr/bin/env bash
# SCRAP 정식 배포 (docs/deploy-azure.md)
#
#   deploy/azure/deploy.sh core      # 1단계: 네트워크·DB·Key Vault·ACR·관리 ID·모니터링
#   deploy/azure/deploy.sh secrets   # Key Vault에 비밀값 넣기 (이미 있는 값은 그대로 둠)
#   deploy/azure/deploy.sh images    # 4개 레포의 브랜치(기본 main)를 빌드해 ACR에 :main 태그로 올림
#   deploy/azure/deploy.sh apps      # 2단계: App Service 앱 4개·배포 웹훅 + Front Door/WAF
#   deploy/azure/deploy.sh all       # 위 네 단계를 순서대로
#
# 필요한 것: az(로그인 상태), docker, git. scrap-infra/.env에서 Azure OpenAI 값과 Mapbox 토큰을 읽음
# 비밀값은 화면에 출력하지 않음
# 앱이 만들어진 뒤에는 images만 다시 실행해도 웹훅으로 App Service가 새 이미지를 받음
#
# 환경 변수로 바꿀 수 있는 값
#   RG=TEAM_AIBIC2026_01_RG_EUS2  BRANCH=main
#   ALERT_EMAIL=  CUSTOM_HOST=  GOOGLE_CLIENT_ID=  MICROSOFT_CLIENT_ID=  MICROSOFT_TENANT=common

set -euo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$INFRA/.." && pwd)"
# 부트캠프 구독은 리소스 그룹을 새로 만들 수 없어 받은 그룹을 씀
RG="${RG:-TEAM_AIBIC2026_01_RG_EUS2}"
BRANCH="${BRANCH:-main}"
# App Service가 따라가는 태그. 이 태그로 push하면 웹훅으로 다시 배포됨
DEPLOY_TAG=main
STATE="$INFRA/.azure-state"   # 처음 만든 DB 비밀번호를 Key Vault로 옮기기 전 잠깐 둠 (git 제외)
mkdir -p "$STATE"

die() { echo "오류: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "$1 이 필요함"; }

# .env에서 값 하나 읽기 (출력하지 않음)
envval() {
	[ -f "$INFRA/.env" ] || { echo ""; return; }
	grep -E "^$1=" "$INFRA/.env" | tail -1 | cut -d= -f2- | tr -d '\r' | sed -E "s/^['\"]|['\"]$//g"
}

kv_name() { az keyvault list -g "$RG" --query "[0].name" -o tsv 2>/dev/null; }
acr_name() { az acr list -g "$RG" --query "[0].name" -o tsv 2>/dev/null; }

kv_has() { az keyvault secret show --vault-name "$1" -n "$2" --query id -o tsv >/dev/null 2>&1; }

# 권한이 막 부여된 직후에는 몇 분 동안 403이 날 수 있어 다시 시도함
kv_set() {
	local vault=$1 name=$2 value=$3 i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if az keyvault secret set --vault-name "$vault" -n "$name" --value "$value" -o none 2>/dev/null; then
			echo "  설정 $name"; return 0
		fi
		sleep 15
	done
	die "Key Vault에 $name 을 넣지 못함 (권한 반영을 기다린 뒤 다시 실행)"
}

kv_get() { az keyvault secret show --vault-name "$1" -n "$2" --query value -o tsv; }

# PostgreSQL 비밀번호: 대문자·소문자·숫자 포함, URL에 그대로 쓸 수 있게 영문·숫자만
new_password() { echo "Sc$(openssl rand -hex 16)9X"; }

pg_password() {
	local vault
	vault=$(kv_name)
	if [ -n "$vault" ] && kv_has "$vault" postgres-admin-password; then
		kv_get "$vault" postgres-admin-password
	elif [ -f "$STATE/pg.pw" ]; then
		cat "$STATE/pg.pw"
	else
		new_password | tee "$STATE/pg.pw"
	fi
}

common_params() {
	local deployer apiver
	deployer=$(az ad signed-in-user show --query id -o tsv)
	apiver=$(envval DIAGNOSIS_AZURE_OPENAI_API_VERSION)
	PARAMS=(
		deployerObjectId="$deployer"
		postgresAdminPassword="$(pg_password)"
		diagnosisOpenAiEndpoint="$(envval DIAGNOSIS_AZURE_OPENAI_ENDPOINT)"
		diagnosisOpenAiDeployment="$(envval DIAGNOSIS_AZURE_OPENAI_DEPLOYMENT)"
		diagnosisOpenAiApiVersion="${apiver:-2024-10-21}"
		routeOpenAiEndpoint="$(envval ROUTE_AZURE_OPENAI_ENDPOINT)"
		routeOpenAiDeployment="$(envval ROUTE_AZURE_OPENAI_DEPLOYMENT)"
		googleClientId="${GOOGLE_CLIENT_ID:-}"
		microsoftClientId="${MICROSOFT_CLIENT_ID:-}"
		microsoftTenant="${MICROSOFT_TENANT:-common}"
		customHost="${CUSTOM_HOST:-}"
		alertEmail="${ALERT_EMAIL:-}"
	)
}

deploy_bicep() {
	local apps=$1
	common_params
	echo "== Bicep 배포 (deployApps=$apps) → $RG"
	az deployment group create -g "$RG" -n "scrap-$(date +%Y%m%d%H%M%S)" \
		-f "$INFRA/azure/main.bicep" \
		-p "${PARAMS[@]}" deployApps="$apps" imageTag="$DEPLOY_TAG" \
		--query "properties.outputs.{publicUrl:publicUrl.value, frontDoorHost:frontDoorHost.value, webHost:webHost.value, acr:acrName.value, keyVault:keyVaultName.value, postgres:postgresHost.value}" -o json
}

cmd_core() {
	need az
	deploy_bicep false
	# 처음 만든 DB 비밀번호를 Key Vault로 옮기고 로컬 파일은 지움
	local vault
	vault=$(kv_name)
	if [ -f "$STATE/pg.pw" ]; then
		kv_has "$vault" postgres-admin-password || kv_set "$vault" postgres-admin-password "$(cat "$STATE/pg.pw")"
		rm -f "$STATE/pg.pw"
	fi
}

cmd_secrets() {
	need az; need openssl
	local vault host user pw
	vault=$(kv_name); [ -n "$vault" ] || die "Key Vault가 없음. core를 먼저 실행"
	host=$(az postgres flexible-server list -g "$RG" --query "[0].fullyQualifiedDomainName" -o tsv)
	user=$(az postgres flexible-server list -g "$RG" --query "[0].administratorLogin" -o tsv)
	pw=$(kv_get "$vault" postgres-admin-password)
	echo "== Key Vault $vault"

	local s
	for s in jwt-secret session-secret; do
		kv_has "$vault" $s || kv_set "$vault" $s "$(openssl rand -hex 32)"
	done
	for s in engine-service-token intake-service-token; do
		kv_has "$vault" $s || kv_set "$vault" $s "$(openssl rand -hex 24)"
	done
	# DB 주소는 비밀번호가 바뀌어도 맞도록 항상 다시 씀
	kv_set "$vault" server-database-url "postgresql+asyncpg://$user:$pw@$host:5432/scrap_server"
	kv_set "$vault" diagnosis-database-url "postgresql+psycopg://$user:$pw@$host:5432/scrap_engine?sslmode=require"

	local key
	key=$(envval DIAGNOSIS_AZURE_OPENAI_API_KEY)
	kv_has "$vault" diagnosis-openai-key || kv_set "$vault" diagnosis-openai-key "${key:-unset}"
	key=$(envval ROUTE_AZURE_OPENAI_API_KEY)
	kv_has "$vault" route-openai-key || kv_set "$vault" route-openai-key "${key:-unset}"
	# 소셜 로그인 비밀값은 앱 등록 뒤 포털이나 az keyvault secret set으로 바꿈
	for s in google-client-secret microsoft-client-secret; do
		kv_has "$vault" $s || kv_set "$vault" $s unset
	done
}

# git 브랜치의 내용만 묶어 빌드함 (로컬 작업 중인 파일은 들어가지 않음)
# :main(App Service가 따라가는 태그)과 :<커밋>(되돌릴 때 쓰는 기록) 두 태그로 올림
build_push() {
	local repo=$1 subdir=$2 server=$3; shift 3
	local dir="$ROOT/$repo" sha
	[ -d "$dir/.git" ] || die "$dir 이 없음"
	git -C "$dir" fetch -q origin "$BRANCH"
	sha=$(git -C "$dir" rev-parse --short=12 "origin/$BRANCH")
	echo "== $repo ($BRANCH $sha)"
	git -C "$dir" archive --format=tar "origin/$BRANCH${subdir:+:$subdir}" \
		| docker build -q "$@" -t "$server/$repo:$sha" -t "$server/$repo:$DEPLOY_TAG" - >/dev/null
	docker push -q "$server/$repo:$sha" >/dev/null
	docker push -q "$server/$repo:$DEPLOY_TAG" >/dev/null
}

cmd_images() {
	need az; need docker; need git
	local acr server
	acr=$(acr_name); [ -n "$acr" ] || die "ACR이 없음. core를 먼저 실행"
	server=$(az acr show -n "$acr" --query loginServer -o tsv)
	az acr login -n "$acr" >/dev/null
	build_push scrap-server backend "$server"
	build_push scrap-diagnosis "" "$server"
	build_push scrap-route "" "$server"
	build_push scrap-web "" "$server" \
		--build-arg VITE_MAPBOX_ACCESS_TOKEN="$(envval VITE_MAPBOX_ACCESS_TOKEN)" \
		--build-arg VITE_ENABLE_DEV_LOGIN=false
}

cmd_apps() {
	need az
	deploy_bicep true
}

case "${1:-}" in
	core) cmd_core ;;
	secrets) cmd_secrets ;;
	images) cmd_images ;;
	apps) cmd_apps ;;
	all) cmd_core; cmd_secrets; cmd_images; cmd_apps ;;
	*) sed -n '2,16p' "$0"; exit 2 ;;
esac
