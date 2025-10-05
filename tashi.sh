#!/usr/bin/env bash
set -Eeuo pipefail

# ========= АВТОМАТИЧЕСКАЯ УСТАНОВКА ЗАВИСИМОСТЕЙ =========
check_and_install_deps() {
  echo -e "\033[1;36m>>> Проверка зависимостей...\033[0m"

  install_pkg() {
    local pkg="$1"
    if ! dpkg -s "$pkg" &>/dev/null; then
      echo "Устанавливаю $pkg..."
      sudo apt update -y >/dev/null
      sudo apt install -y "$pkg" >/dev/null
    fi
  }

  install_pkg "curl"
  install_pkg "jq"

  if ! command -v docker &>/dev/null; then
    echo "Docker не найден, устанавливаю..."
    sudo apt update -y >/dev/null
    sudo apt install -y ca-certificates curl gnupg lsb-release >/dev/null

    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" |
      sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt update -y >/dev/null
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    echo "✅ Docker установлен."
  fi

  if ! sudo systemctl is-active --quiet docker; then
    echo "Запускаю Docker..."
    sudo systemctl enable docker >/dev/null
    sudo systemctl start docker
  fi

  if ! groups "$USER" | grep -q docker; then
    echo "Добавляю пользователя в группу docker..."
    sudo usermod -aG docker "$USER"
    echo "Пользователь добавлен в группу docker. Перезапусти терминал, чтобы применились права."
  fi

  echo -e "\033[1;32mВсе зависимости установлены.\033[0m"
}

check_and_install_deps

# ========= НАСТРОЙКИ =========
IMAGE_TAG='ghcr.io/tashigg/tashi-depin-worker:0'
RUST_LOG='info,tashi_depin_worker=debug,tashi_depin_common=debug'
CONTAINER_PREFIX="tashi-worker"
VOLUME_PREFIX="tashi-auth"
BASE_AGENT_PORT=39065
BASE_METRICS_PORT=19000
AUTO_UPDATE_DEFAULT="n"
PLATFORM_ARG=""
PULL_FLAG="--pull=always"
RUNTIME="docker"
SUDO_DOCKER=""

# ========= УТИЛИТЫ =========
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; RESET="\e[0m"; BOLD="\e[1m"
pause() { read -rp $'\nНажмите Enter, чтобы продолжить...'; }
msg() { printf "%b%s%b\n" "$CYAN" "$*" "$RESET"; }
ok()  { printf "%b%s%b\n" "$GREEN" "$*" "$RESET"; }
warn(){ printf "%b%s%b\n" "$YELLOW" "$*" "$RESET"; }
err() { printf "%b%s%b\n" "$RED" "$*" "$RESET"; }

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    err "Docker не найден."
    exit 1
  fi
  RUNTIME="docker"
  if ! docker ps >/dev/null 2>&1; then
    SUDO_DOCKER="sudo "
  else
    SUDO_DOCKER=""
  fi
}

name_for()   { echo "${CONTAINER_PREFIX}-$1"; }
vol_for()    { echo "${VOLUME_PREFIX}-$1"; }
aport_for()  { echo $((BASE_AGENT_PORT + $1 - 1)); }
mport_for()  { echo $((BASE_METRICS_PORT + $1 - 1)); }

max_index() {
  local max=0 line n
  while read -r line; do
    [[ -z "$line" ]] && continue
    n="${line##*-}"
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    (( n > max )) && max=$n
  done < <(${SUDO_DOCKER}${RUNTIME} ps -a --format '{{.Names}}' | grep -E "^${CONTAINER_PREFIX}-[0-9]+$" || true)
  echo "$max"
}

ensure_volume() {
  local vol="$1"
  if ! ${SUDO_DOCKER}${RUNTIME} volume inspect "$vol" >/dev/null 2>&1; then
    ${SUDO_DOCKER}${RUNTIME} volume create "$vol" >/dev/null
  fi
}

input_number() {
  local prompt="$1" var
  while :; do
    read -rp "$prompt" var || exit 1
    [[ "$var" =~ ^[0-9]+$ ]] && { echo "$var"; return 0; }
    warn "Введите целое число."
  done
}

input_yesno() {
  local prompt="$1" def="${2:-y}" ans
  read -rp "$prompt" ans || exit 1
  ans="${ans:-$def}"
  case "$ans" in
    y|Y) echo "y";;
    n|N) echo "n";;
    *)   echo "$def";;
  esac
}

# ========= ОСНОВНЫЕ ОПЕРАЦИИ =========
interactive_setup() {
  local idx="$1"
  local cname; cname=$(name_for "$idx")
  local vname; vname=$(vol_for "$idx")
  ensure_volume "$vname"

  msg "Interactive setup для ${cname}..."
  ${SUDO_DOCKER}${RUNTIME} run --rm -it \
    --mount "type=volume,src=${vname},dst=/home/worker/auth" \
    ${PULL_FLAG} ${PLATFORM_ARG} \
    "${IMAGE_TAG}" \
    interactive-setup /home/worker/auth
}

run_instance() {
  local idx="$1"
  local auto="${2:-$AUTO_UPDATE_DEFAULT}"
  local cname; cname=$(name_for "$idx")
  local vname; vname=$(vol_for "$idx")
  local aport; aport=$(aport_for "$idx")
  local mport; mport=$(mport_for "$idx")

  ensure_volume "$vname"

  local auto_arg=""
  [[ "$auto" == "y" || "$auto" == "Y" ]] && auto_arg="--unstable-update-download-path /tmp/tashi-depin-worker"

  local pub_ip="" pub_arg=""
  if command -v curl >/dev/null 2>&1; then pub_ip=$(curl -s --max-time 2 https://api.ipify.org || true); fi
  [[ -n "$pub_ip" ]] && pub_arg="--agent-public-addr=${pub_ip}:${aport}"

  msg "Старт ${cname} (agent:${aport}, metrics:127.0.0.1:${mport})"
  ${SUDO_DOCKER}${RUNTIME} run -d \
    -p "${aport}:${aport}" \
    -p "127.0.0.1:${mport}:9000" \
    --mount "type=volume,src=${vname},dst=/home/worker/auth" \
    --name "${cname}" \
    -e "RUST_LOG=${RUST_LOG}" \
    --label "tashi.instance=${idx}" \
    --label "tashi.agent_port=${aport}" \
    --label "tashi.metrics_port=${mport}" \
    --restart=on-failure \
    ${PULL_FLAG} ${PLATFORM_ARG} \
    "${IMAGE_TAG}" \
    run /home/worker/auth \
    ${auto_arg} \
    ${pub_arg} >/dev/null

  ok "${cname}: запущен"
}

list_instances() {
  ensure_docker
  printf "%b\n" "${BOLD}Ид | Имя               | Статус           | AgentPort | MetricsPort | Образ${RESET}"
  printf -- "----+-------------------+------------------+-----------+-------------+------------------------------\n"
  ${SUDO_DOCKER}${RUNTIME} ps -a --format '{{.Names}}|{{.Status}}|{{.Image}}' \
    | grep -E "^${CONTAINER_PREFIX}-[0-9]+\|" | while IFS='|' read -r name status image; do
        idx="${name##*-}"
        aport="$(${SUDO_DOCKER}${RUNTIME} inspect -f '{{index .Config.Labels "tashi.agent_port"}}' "$name" 2>/dev/null || true)"
        mport="$(${SUDO_DOCKER}${RUNTIME} inspect -f '{{index .Config.Labels "tashi.metrics_port"}}' "$name" 2>/dev/null || true)"
        printf "%-3s| %-18s| %-17s| %-10s| %-11s| %s\n" "$idx" "$name" "$status" "${aport:-?}" "${mport:-?}" "$image"
      done
}

add_one() {
  ensure_docker
  local auto platform
  auto=$(input_yesno "Включить автообновления? (y/n) [y] > " "y")
  read -rp "PLATFORM (пусто или, например, linux/amd64) > " platform || true
  PLATFORM_ARG=""
  [[ -n "${platform:-}" ]] && PLATFORM_ARG="--platform ${platform}"

  local idx=$(( $(max_index) + 1 ))
  interactive_setup "$idx"
  run_instance "$idx" "$auto"
  ok "Готово."
}

# ... остальные функции (start_stop_restart_one, logs_one, update_target, remove_target, bulk_ops, settings_menu, instance_menu) без изменений ...

# ========= ГЛАВНОЕ МЕНЮ =========
main_menu() {
  ensure_docker
  while :; do
    clear
    echo -e "${BOLD}Tashi DePIN Multi-Manager${RESET}"
    echo "1) Добавить один инстанс"
    echo "2) Список/Статусы"
    echo "3) Массовые действия (start/stop/restart)"
    echo "4) Управление инстансом"
    echo "5) Настройки"
    echo "0) Выход"
    read -rp "Выбор > " choice || exit 0
    case "$choice" in
      1) add_one; pause;;
      2) list_instances; pause;;
      3) bulk_ops; pause;;
      4) instance_menu;;
      5) settings_menu;;
      0) exit 0;;
      *) warn "Неверный выбор"; pause;;
    esac
  done
}

main_menu
