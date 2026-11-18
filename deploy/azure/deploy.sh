#!/usr/bin/env bash
# SCRAP 정식 배포 (docs/deploy-azure.md)
#
#   deploy/azure/deploy.sh core      # 1단계: 네트워크·DB·Key Vault·ACR·관리 ID·모니터링
#   deploy/azure/deploy.sh secrets   # Key Vault에 비밀값 넣기 (이미 있는 값은 그대로 둠)
#   deploy/azure/deploy.sh images    # 4개 레포의 브랜치(기본 main)를 빌드해 ACR에 :main 태그로 올림
#   deploy/azure/deploy.sh apps      # 2단계: App Service 앱 4개·배포 웹훅 + Front Door/WAF
#   deploy/azure/deploy.sh seed      # 공정 참조 데이터 적재 (server 이미지가 ACR에 올라간 뒤)
#   deploy/azure/deploy.sh demo on|off|status          # 시연용 업체 연결 허용 켜기·끄기 (server 앱 설정)
#   deploy/azure/deploy.sh demo-bind <이메일> <업체키>...  # 로그인·기업 등록한 계정을 업체에 시연용으로 연결
#   deploy/azure/deploy.sh all       # 위 네 단계를 순서대로
#
# 필요한 것: az(로그인 상태), docker, git. scrap-infra/.env에서 Azure OpenAI 값과 Mapbox 토큰을 읽음
# 비밀값은 화면에 출력하지 않음
# 앱이 만들어진 뒤에는 images만 다시 실행해도 웹훅으로 App Service가 새 이미지를 받음
#
# 환경 변수로 바꿀 수 있는 값
#   RG=TEAM_AIBIC2026_01_RG_EUS2  BRANCH=main
#   ALERT_EMAIL=  CUSTOM_HOST=  GOOGLE_CLIENT_ID=  MICROSOFT_CLIENT_ID=  MICROSOFT_TENANT=common
#   DEMO_FACILITY_BINDINGS=true|false (넘기지 않으면 지금 값 유지)

set -euo pipefail

INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT="$(cd "$INFRA/.." && pwd)"
# 부트캠프 구독은 리소스 그룹을 새로 만들 수 없어 받은 그룹을 씀
RG="${RG:-TEAM_AIBIC2026_01_RG_EUS2}"
BRANCH="${BRANCH:-main}"
# DB VM 관리용 SSH 공개 키 (VM에 공용 IP가 없어 평소에는 az vm run-command로 관리)
DB_SSH_KEY="${DB_SSH_KEY:-$HOME/.ssh/scrap_key.pub}"
# DB VM의 고정 사설 IP와 관리자 (azure/main.bicep과 같은 값)
DB_HOST=10.0.2.4
DB_USER=scrapadmin
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

# 리소스 그룹에 다른 팀원 리소스도 있으므로 이 구성이 만든 이름만 고름
kv_name() { az keyvault list -g "$RG" --query "[?starts_with(name,'kv-scrap-')].name | [0]" -o tsv 2>/dev/null; }
acr_name() { az acr list -g "$RG" --query "[?starts_with(name,'crscrap')].name | [0]" -o tsv 2>/dev/null; }

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

# 이미 배포된 server 앱 설정 값 하나 (환경 변수로 넘기지 않은 값은 지금 값을 그대로 씀)
current_setting() {
	local app
	app=$(az webapp list -g "$RG" --query "[?starts_with(name,'scrap-server-')].name | [0]" -o tsv 2>/dev/null)
	[ -n "$app" ] || return 0
	az webapp config appsettings list -g "$RG" -n "$app" --query "[?name=='$1'].value | [0]" -o tsv 2>/dev/null
}

common_params() {
	local deployer apiver
	# 소셜 로그인·도메인 값은 넘기지 않으면 지금 배포된 값을 유지함 (빈 값으로 덮어쓰지 않게)
	: "${GOOGLE_CLIENT_ID:=$(current_setting GOOGLE_CLIENT_ID)}"
	: "${MICROSOFT_CLIENT_ID:=$(current_setting MICROSOFT_CLIENT_ID)}"
	: "${MICROSOFT_TENANT:=$(current_setting MICROSOFT_TENANT)}"
	: "${DEMO_FACILITY_BINDINGS:=$(current_setting DEMO_FACILITY_BINDINGS)}"
	if [ -z "${CUSTOM_HOST:-}" ]; then
		local url; url=$(current_setting FRONTEND_URL)
		case "$url" in *azurefd.net*|"") ;; *) CUSTOM_HOST=${url#https://} ;; esac
	fi
	deployer=$(az ad signed-in-user show --query id -o tsv)
	apiver=$(envval DIAGNOSIS_AZURE_OPENAI_API_VERSION)
	[ -f "$DB_SSH_KEY" ] || die "DB VM용 SSH 공개 키가 없음: $DB_SSH_KEY (DB_SSH_KEY로 지정)"
	# OCR은 Key Vault에 실제 키가 있을 때만 켬. 키 자리값(unset)이면 엔진이 켜진 것으로 보고 업로드마다 401이 남
	local ocr=false vault ocrkey
	if [ "$(envval DIAGNOSIS_ALLOW_DOCUMENT_OCR)" = true ]; then
		vault=$(kv_name)
		ocrkey=$([ -n "$vault" ] && kv_get "$vault" diagnosis-docintel-key 2>/dev/null || true)
		if [ -n "$ocrkey" ] && [ "$ocrkey" != unset ]; then ocr=true
		else echo "경고: Key Vault에 OCR 키(diagnosis-docintel-key)가 없어 OCR을 끈 채 배포함. secrets 단계 뒤 apps를 다시 실행" >&2; fi
	fi
	PARAMS=(
		deployerObjectId="$deployer"
		postgresAdminPassword="$(pg_password)"
		dbVmSshPublicKey="$(cat "$DB_SSH_KEY")"
		diagnosisOpenAiEndpoint="$(envval DIAGNOSIS_AZURE_OPENAI_ENDPOINT)"
		diagnosisOpenAiDeployment="$(envval DIAGNOSIS_AZURE_OPENAI_DEPLOYMENT)"
		diagnosisOpenAiApiVersion="${apiver:-2024-10-21}"
		diagnosisAllowDocumentOcr="$ocr"
		diagnosisDocIntelEndpoint="$(envval DIAGNOSIS_AZURE_DOCINTEL_ENDPOINT)"
		routeOpenAiEndpoint="$(envval ROUTE_AZURE_OPENAI_ENDPOINT)"
		routeOpenAiDeployment="$(envval ROUTE_AZURE_OPENAI_DEPLOYMENT)"
		googleClientId="${GOOGLE_CLIENT_ID:-}"
		microsoftClientId="${MICROSOFT_CLIENT_ID:-}"
		microsoftTenant="${MICROSOFT_TENANT:-common}"
		demoFacilityBindings="$([ "${DEMO_FACILITY_BINDINGS:-}" = true ] && echo true || echo false)"
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
	host=$DB_HOST
	user=$DB_USER
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
	kv_set "$vault" diagnosis-database-url "postgresql+psycopg://$user:$pw@$host:5432/scrap_engine"

	local key
	key=$(envval DIAGNOSIS_AZURE_OPENAI_API_KEY)
	kv_has "$vault" diagnosis-openai-key || kv_set "$vault" diagnosis-openai-key "${key:-unset}"
	# OCR 키는 넣었을 때만 덮어씀(빈 값이면 기존 값 유지, 처음이면 unset)
	key=$(envval DIAGNOSIS_AZURE_DOCINTEL_API_KEY)
	if [ -n "$key" ]; then kv_set "$vault" diagnosis-docintel-key "$key"
	else kv_has "$vault" diagnosis-docintel-key || kv_set "$vault" diagnosis-docintel-key unset; fi
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

# DB VM에서 ACR 이미지를 한 번 실행함. App Service 컨테이너에는 SSH로 들어갈 수 없고,
# App Service 시작 명령은 따옴표를 풀지 않아 'a && b' 같은 명령을 쓸 수 없음
run_on_db_vm() {
	local image=$1 db=$2 cmd=$3
	local acr server acr_user acr_pw vault db_pw
	acr=$(acr_name); vault=$(kv_name)
	[ -n "$acr" ] && [ -n "$vault" ] || die "ACR이나 Key Vault가 없음"
	server=$(az acr show -n "$acr" --query loginServer -o tsv)
	acr_user=$(az acr credential show -n "$acr" --query username -o tsv)
	acr_pw=$(az acr credential show -n "$acr" --query "passwords[0].value" -o tsv)
	db_pw=$(kv_get "$vault" postgres-admin-password)
	az vm run-command invoke -g "$RG" -n vm-scrap-db --command-id RunShellScript --query "value[0].message" -o tsv \
		--scripts "echo '$acr_pw' | docker login $server -u $acr_user --password-stdin >/dev/null 2>&1 && docker pull -q $server/$image:$DEPLOY_TAG >/dev/null && docker run --rm --network host -e DATABASE_URL='${db//PASSWORD/$db_pw}' $server/$image:$DEPLOY_TAG sh -c '$cmd' 2>&1 | tail -5; docker logout $server >/dev/null" \
		| grep -vE "^\[std(out|err)\]$|^Enable succeeded" || true
}

# 엔진 DB 마이그레이션과 공정 참조 데이터 적재. 이미지가 main에 올라간 뒤 실행함
# 참조 데이터는 실행할 때마다 갈아끼움 (compose의 server-seed와 같음)
cmd_seed() {
	need az
	echo "== 엔진 DB 마이그레이션 (scrap-diagnosis)"
	run_on_db_vm scrap-diagnosis "postgresql+psycopg://$DB_USER:PASSWORD@127.0.0.1:5432/scrap_engine" "alembic upgrade head"
	echo "== 공정 참조 데이터 적재 (scrap-server)"
	run_on_db_vm scrap-server "postgresql+asyncpg://$DB_USER:PASSWORD@127.0.0.1:5432/scrap_server" \
		"alembic upgrade head >/dev/null && python -m app.domains.treatment.import_catalog"
}

server_app() {
	az webapp list -g "$RG" --query "[?starts_with(name,'scrap-server-')].name | [0]" -o tsv
}

# 시연용(synthetic) 업체 연결 허용. 바꾸면 server 앱이 다시 시작됨
# apps를 다시 실행해도 지금 값을 유지함 (common_params)
cmd_demo() {
	need az
	local app; app=$(server_app); [ -n "$app" ] || die "server 앱이 없음"
	case "${1:-status}" in
		on|off)
			az webapp config appsettings set -g "$RG" -n "$app" 				--settings DEMO_FACILITY_BINDINGS="$([ "$1" = on ] && echo true || echo false)" -o none
			echo "DEMO_FACILITY_BINDINGS=$([ "$1" = on ] && echo true || echo false) ($app 재시작됨)" ;;
		status) echo "DEMO_FACILITY_BINDINGS=$(current_setting DEMO_FACILITY_BINDINGS)" ;;
		*) die "demo on|off|status" ;;
	esac
}

# 소셜 로그인 후 기업 등록까지 마친 계정을 업체 키에 시연용으로 연결 (실제 반입 승인 아님)
cmd_demo_bind() {
	need az
	local email=${1:-}; shift || true
	[ -n "$email" ] && [ $# -gt 0 ] || die "demo-bind <이메일> <업체키>..."
	local args="--email $email" key
	[[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]] || die "이메일 형식이 아님: $email"
	for key in "$@"; do
		[[ "$key" =~ ^[a-z0-9-]+$ ]] || die "업체 키 형식이 아님: $key"
		args="$args --facility $key"
	done
	[ "$(current_setting DEMO_FACILITY_BINDINGS)" = true ] || echo "주의: DEMO_FACILITY_BINDINGS가 꺼져 있어 연결해도 화면에 나오지 않음 (demo on)"
	# 스크립트는 DB만 씀. APP_ENV=prod면 JWT 등 앱 비밀값 검사에 걸려서 test로 실행함
	run_on_db_vm scrap-server "postgresql+asyncpg://$DB_USER:PASSWORD@127.0.0.1:5432/scrap_server" 		"APP_ENV=test python -m app.domains.transport.dev_accounts $args"
}

case "${1:-}" in
	core) cmd_core ;;
	secrets) cmd_secrets ;;
	images) cmd_images ;;
	apps) cmd_apps ;;
	seed) cmd_seed ;;
	demo) cmd_demo "${2:-status}" ;;
	demo-bind) shift; cmd_demo_bind "$@" ;;
	all) cmd_core; cmd_secrets; cmd_images; cmd_apps ;;
	*) sed -n '2,16p' "$0"; exit 2 ;;
esac
