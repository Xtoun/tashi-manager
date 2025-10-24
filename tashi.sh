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
    --restart=unless-stopped \
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

start_stop_restart_one() {
  local idx="$1"
  local action="$2"
  local cname; cname=$(name_for "$idx")
  
  case "$action" in
    start)
      if ${SUDO_DOCKER}${RUNTIME} ps -q -f "name=${cname}" | grep -q .; then
        warn "${cname} уже запущен"
      else
        ${SUDO_DOCKER}${RUNTIME} start "${cname}" >/dev/null
        ok "${cname}: запущен"
      fi
      ;;
    stop)
      if ${SUDO_DOCKER}${RUNTIME} ps -q -f "name=${cname}" | grep -q .; then
        ${SUDO_DOCKER}${RUNTIME} stop "${cname}" >/dev/null
        ok "${cname}: остановлен"
      else
        warn "${cname} не запущен"
      fi
      ;;
    restart)
      ${SUDO_DOCKER}${RUNTIME} restart "${cname}" >/dev/null
      ok "${cname}: перезапущен"
      ;;
  esac
}

logs_one() {
  local idx="$1"
  local cname; cname=$(name_for "$idx")
  
  if ! ${SUDO_DOCKER}${RUNTIME} ps -a -q -f "name=${cname}" | grep -q .; then
    err "Контейнер ${cname} не найден"
    return 1
  fi
  
  msg "Логи ${cname} (Ctrl+C для выхода):"
  ${SUDO_DOCKER}${RUNTIME} logs -f "${cname}"
}

update_target() {
  local idx="$1"
  local cname; cname=$(name_for "$idx")
  
  if ! ${SUDO_DOCKER}${RUNTIME} ps -a -q -f "name=${cname}" | grep -q .; then
    err "Контейнер ${cname} не найден"
    return 1
  fi
  
  msg "Обновление ${cname}..."
  ${SUDO_DOCKER}${RUNTIME} pull ${PLATFORM_ARG} "${IMAGE_TAG}" >/dev/null
  ${SUDO_DOCKER}${RUNTIME} stop "${cname}" >/dev/null
  ${SUDO_DOCKER}${RUNTIME} rm "${cname}" >/dev/null
  
  local vname; vname=$(vol_for "$idx")
  local aport; aport=$(aport_for "$idx")
  local mport; mport=$(mport_for "$idx")
  
  local auto_arg="--unstable-update-download-path /tmp/tashi-depin-worker"
  local pub_ip="" pub_arg=""
  if command -v curl >/dev/null 2>&1; then pub_ip=$(curl -s --max-time 2 https://api.ipify.org || true); fi
  [[ -n "$pub_ip" ]] && pub_arg="--agent-public-addr=${pub_ip}:${aport}"
  
  ${SUDO_DOCKER}${RUNTIME} run -d \
    -p "${aport}:${aport}" \
    -p "127.0.0.1:${mport}:9000" \
    --mount "type=volume,src=${vname},dst=/home/worker/auth" \
    --name "${cname}" \
    -e "RUST_LOG=${RUST_LOG}" \
    --label "tashi.instance=${idx}" \
    --label "tashi.agent_port=${aport}" \
    --label "tashi.metrics_port=${mport}" \
    --restart=unless-stopped \
    ${PULL_FLAG} ${PLATFORM_ARG} \
    "${IMAGE_TAG}" \
    run /home/worker/auth \
    ${auto_arg} \
    ${pub_arg} >/dev/null
  
  ok "${cname}: обновлен и запущен"
}

remove_target() {
  local idx="$1"
  local cname; cname=$(name_for "$idx")
  local vname; vname=$(vol_for "$idx")
  
  if ! ${SUDO_DOCKER}${RUNTIME} ps -a -q -f "name=${cname}" | grep -q .; then
    err "Контейнер ${cname} не найден"
    return 1
  fi
  
  local confirm
  confirm=$(input_yesno "Удалить ${cname} и его данные? (y/n) [n] > " "n")
  if [[ "$confirm" == "y" ]]; then
    ${SUDO_DOCKER}${RUNTIME} stop "${cname}" >/dev/null 2>&1 || true
    ${SUDO_DOCKER}${RUNTIME} rm "${cname}" >/dev/null
    ${SUDO_DOCKER}${RUNTIME} volume rm "${vname}" >/dev/null 2>&1 || true
    ok "${cname}: удален"
  else
    msg "Отменено"
  fi
}

bulk_ops() {
  ensure_docker
  list_instances
  echo
  echo "1) Запустить все"
  echo "2) Остановить все"
  echo "3) Перезапустить все"
  echo "4) Обновить все"
  echo "0) Назад"
  read -rp "Выбор > " choice || return 0
  
  case "$choice" in
    1)
      msg "Запуск всех инстансов..."
      ${SUDO_DOCKER}${RUNTIME} ps -a --format '{{.Names}}' | grep -E "^${CONTAINER_PREFIX}-[0-9]+$" | while read -r name; do
        idx="${name##*-}"
        start_stop_restart_one "$idx" "start"
      done
      ;;
    2)
      msg "Остановка всех инстансов..."
      ${SUDO_DOCKER}${RUNTIME} ps -q -f "label=tashi.instance" | while read -r id; do
        ${SUDO_DOCKER}${RUNTIME} stop "$id" >/dev/null
      done
      ok "Все инстансы остановлены"
      ;;
    3)
      msg "Перезапуск всех инстансов..."
      ${SUDO_DOCKER}${RUNTIME} ps -a --format '{{.Names}}' | grep -E "^${CONTAINER_PREFIX}-[0-9]+$" | while read -r name; do
        idx="${name##*-}"
        start_stop_restart_one "$idx" "restart"
      done
      ;;
    4)
      msg "Обновление всех инстансов..."
      ${SUDO_DOCKER}${RUNTIME} pull ${PLATFORM_ARG} "${IMAGE_TAG}" >/dev/null
      ${SUDO_DOCKER}${RUNTIME} ps -a --format '{{.Names}}' | grep -E "^${CONTAINER_PREFIX}-[0-9]+$" | while read -r name; do
        idx="${name##*-}"
        update_target "$idx"
      done
      ;;
    0) return 0;;
    *) warn "Неверный выбор"; pause;;
  esac
}

migrate_containers() {
  local old_prefix="$1"
  local new_prefix="$2"
  
  local containers=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && containers+=("$name")
  done < <(${SUDO_DOCKER}${RUNTIME} ps -a --format '{{.Names}}' | grep -E "^${old_prefix}-[0-9]+$" || true)
  
  if [[ ${#containers[@]} -eq 0 ]]; then
    msg "Нет контейнеров со старым префиксом для миграции"
    return 0
  fi
  
  echo "Найдены контейнеры для миграции:"
  for container in "${containers[@]}"; do
    echo "  - $container"
  done
  echo
  
  local confirm
  confirm=$(input_yesno "Переименовать все контейнеры на новый префикс? (y/n) [n] > " "n")
  if [[ "$confirm" != "y" ]]; then
    msg "Миграция отменена"
    return 0
  fi
  
  msg "Начинаю миграцию контейнеров..."
  for container in "${containers[@]}"; do
    local idx="${container##*-}"
    local new_name="${new_prefix}-${idx}"
    
    if ${SUDO_DOCKER}${RUNTIME} ps -q -f "name=${new_name}" | grep -q .; then
      warn "Контейнер ${new_name} уже существует, пропускаю ${container}"
      continue
    fi
    
    msg "Переименовываю ${container} -> ${new_name}"
    ${SUDO_DOCKER}${RUNTIME} rename "${container}" "${new_name}" >/dev/null
    if [[ $? -eq 0 ]]; then
      ok "${container} переименован в ${new_name}"
    else
      err "Ошибка переименования ${container}"
    fi
  done
  
  ok "Миграция завершена"
}

apply_settings_changes() {
  local old_prefix="$1"
  local new_prefix="$2"
  
  if [[ "$old_prefix" != "$new_prefix" ]]; then
    warn "ВНИМАНИЕ: Изменение префикса контейнера!"
    warn "Старый префикс: $old_prefix"
    warn "Новый префикс: $new_prefix"
    echo
    echo "Это изменение повлияет на:"
    echo "- Новые контейнеры будут создаваться с новым префиксом"
    echo "- Существующие контейнеры останутся со старым префиксом"
    echo "- Для работы с существующими контейнерами используйте старый префикс"
    echo
    local confirm
    confirm=$(input_yesno "Продолжить изменение? (y/n) [y] > " "y")
    if [[ "$confirm" != "y" ]]; then
      CONTAINER_PREFIX="$old_prefix"
      msg "Изменение отменено"
      return 1
    fi
    
    # Предложить миграцию существующих контейнеров
    echo
    migrate_containers "$old_prefix" "$new_prefix"
  fi
  return 0
}

settings_menu() {
  while :; do
    clear
    echo -e "${BOLD}Настройки${RESET}"
    echo "1) Изменить образ (текущий: ${IMAGE_TAG})"
    echo "2) Изменить RUST_LOG (текущий: ${RUST_LOG})"
    echo "3) Изменить базовый порт агента (текущий: ${BASE_AGENT_PORT})"
    echo "4) Изменить базовый порт метрик (текущий: ${BASE_METRICS_PORT})"
    echo "5) Изменить префикс контейнера (текущий: ${CONTAINER_PREFIX})"
    echo "6) Изменить префикс тома (текущий: ${VOLUME_PREFIX})"
    echo "7) Изменить настройку автообновления по умолчанию (текущий: ${AUTO_UPDATE_DEFAULT})"
    echo "8) Показать все настройки"
    echo "0) Назад"
    read -rp "Выбор > " choice || return 0
    
    case "$choice" in
      1)
        read -rp "Новый образ > " new_image || true
        if [[ -n "${new_image:-}" ]]; then
          IMAGE_TAG="$new_image"
          ok "Образ изменен на: ${IMAGE_TAG}"
        else
          warn "Образ не изменен"
        fi
        pause
        ;;
      2)
        read -rp "Новый RUST_LOG > " new_log || true
        if [[ -n "${new_log:-}" ]]; then
          RUST_LOG="$new_log"
          ok "RUST_LOG изменен на: ${RUST_LOG}"
        else
          warn "RUST_LOG не изменен"
        fi
        pause
        ;;
      3)
        new_port=$(input_number "Новый базовый порт агента > ")
        if [[ "$new_port" -ne "$BASE_AGENT_PORT" ]]; then
          BASE_AGENT_PORT="$new_port"
          ok "Базовый порт агента изменен на: ${BASE_AGENT_PORT}"
        else
          warn "Порт не изменен"
        fi
        pause
        ;;
      4)
        new_port=$(input_number "Новый базовый порт метрик > ")
        if [[ "$new_port" -ne "$BASE_METRICS_PORT" ]]; then
          BASE_METRICS_PORT="$new_port"
          ok "Базовый порт метрик изменен на: ${BASE_METRICS_PORT}"
        else
          warn "Порт не изменен"
        fi
        pause
        ;;
      5)
        local old_prefix="$CONTAINER_PREFIX"
        read -rp "Новый префикс контейнера > " new_prefix || true
        if [[ -n "${new_prefix:-}" && "$new_prefix" != "$old_prefix" ]]; then
          CONTAINER_PREFIX="$new_prefix"
          if apply_settings_changes "$old_prefix" "$new_prefix"; then
            ok "Префикс контейнера изменен на: ${CONTAINER_PREFIX}"
          fi
        else
          warn "Префикс не изменен"
        fi
        pause
        ;;
      6)
        read -rp "Новый префикс тома > " new_vol_prefix || true
        if [[ -n "${new_vol_prefix:-}" ]]; then
          VOLUME_PREFIX="$new_vol_prefix"
          ok "Префикс тома изменен на: ${VOLUME_PREFIX}"
        else
          warn "Префикс тома не изменен"
        fi
        pause
        ;;
      7)
        AUTO_UPDATE_DEFAULT=$(input_yesno "Включить автообновления по умолчанию? (y/n) [${AUTO_UPDATE_DEFAULT}] > " "$AUTO_UPDATE_DEFAULT")
        ok "Автообновления по умолчанию: ${AUTO_UPDATE_DEFAULT}"
        pause
        ;;
      8)
        clear
        echo -e "${BOLD}Текущие настройки:${RESET}"
        echo "Образ: ${IMAGE_TAG}"
        echo "RUST_LOG: ${RUST_LOG}"
        echo "Базовый порт агента: ${BASE_AGENT_PORT}"
        echo "Базовый порт метрик: ${BASE_METRICS_PORT}"
        echo "Префикс контейнера: ${CONTAINER_PREFIX}"
        echo "Префикс тома: ${VOLUME_PREFIX}"
        echo "Автообновления по умолчанию: ${AUTO_UPDATE_DEFAULT}"
        echo "Платформа: ${PLATFORM_ARG:-не задана}"
        echo "Флаг pull: ${PULL_FLAG}"
        pause
        ;;
      0) return 0;;
      *) warn "Неверный выбор"; pause;;
    esac
  done
}

instance_menu() {
  ensure_docker
  list_instances
  echo
  local idx
  idx=$(input_number "Номер инстанса (0 для выхода) > ")
  [[ "$idx" -eq 0 ]] && return 0
  
  local cname; cname=$(name_for "$idx")
  if ! ${SUDO_DOCKER}${RUNTIME} ps -a -q -f "name=${cname}" | grep -q .; then
    err "Инстанс ${idx} не найден"
    pause
    return 1
  fi
  
  while :; do
    clear
    echo -e "${BOLD}Управление инстансом ${idx} (${cname})${RESET}"
    echo "1) Запустить"
    echo "2) Остановить"
    echo "3) Перезапустить"
    echo "4) Логи"
    echo "5) Обновить"
    echo "6) Удалить"
    echo "0) Назад"
    read -rp "Выбор > " choice || return 0
    
    case "$choice" in
      1) start_stop_restart_one "$idx" "start"; pause;;
      2) start_stop_restart_one "$idx" "stop"; pause;;
      3) start_stop_restart_one "$idx" "restart"; pause;;
      4) logs_one "$idx"; pause;;
      5) update_target "$idx"; pause;;
      6) remove_target "$idx"; pause;;
      0) return 0;;
      *) warn "Неверный выбор"; pause;;
    esac
  done
}

# ========= АВТОПЕРЕЗАГРУЗКА =========
enable_auto_restart() {
  local script_path="$0"
  local cron_job="0 */2 * * * cd $(dirname "$script_path") && bash $(basename "$script_path") --auto-restart"
  
  # Проверяем, есть ли уже задача автоперезагрузки
  if crontab -l 2>/dev/null | grep -q "tashi.*auto-restart"; then
    warn "Автоперезагрузка уже включена"
    return 1
  fi
  
  # Добавляем задачу в crontab
  (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
  
  if [[ $? -eq 0 ]]; then
    ok "Автоперезагрузка включена. Контейнеры будут перезагружаться каждые 2 часа."
    ok "Cron задача добавлена: $cron_job"
  else
    err "Ошибка добавления задачи в crontab"
    return 1
  fi
}

disable_auto_restart() {
  # Удаляем задачу автоперезагрузки из crontab
  crontab -l 2>/dev/null | grep -v "tashi.*auto-restart" | crontab -
  
  if [[ $? -eq 0 ]]; then
    ok "Автоперезагрузка отключена"
  else
    err "Ошибка удаления задачи из crontab"
    return 1
  fi
}

check_auto_restart_status() {
  if crontab -l 2>/dev/null | grep -q "tashi.*auto-restart"; then
    ok "Автоперезагрузка включена"
    echo "Расписание: каждые 2 часа"
    echo "Задача: $(crontab -l 2>/dev/null | grep "tashi.*auto-restart")"
  else
    warn "Автоперезагрузка отключена"
  fi
}

auto_restart_all_containers() {
  ensure_docker
  msg "Автоматическая перезагрузка всех контейнеров Tashi..."
  
  local restarted_count=0
  ${SUDO_DOCKER}${RUNTIME} ps -a --format '{{.Names}}' | grep -E "^${CONTAINER_PREFIX}-[0-9]+$" | while read -r name; do
    idx="${name##*-}"
    if ${SUDO_DOCKER}${RUNTIME} ps -q -f "name=${name}" | grep -q .; then
      msg "Перезагружаю ${name}..."
      ${SUDO_DOCKER}${RUNTIME} restart "${name}" >/dev/null
      ok "${name}: перезагружен"
      ((restarted_count++))
    fi
  done
  
  if [[ $restarted_count -gt 0 ]]; then
    ok "Перезагружено контейнеров: $restarted_count"
  else
    warn "Нет запущенных контейнеров для перезагрузки"
  fi
}

auto_restart_menu() {
  while :; do
    clear
    echo -e "${BOLD}Автоперезагрузка контейнеров${RESET}"
    echo "1) Включить автоперезагрузку (каждые 2 часа)"
    echo "2) Выключить автоперезагрузку"
    echo "3) Проверить статус автоперезагрузки"
    echo "4) Перезагрузить все контейнеры сейчас"
    echo "0) Назад"
    read -rp "Выбор > " choice || return 0
    
    case "$choice" in
      1) enable_auto_restart; pause;;
      2) disable_auto_restart; pause;;
      3) check_auto_restart_status; pause;;
      4) auto_restart_all_containers; pause;;
      0) return 0;;
      *) warn "Неверный выбор"; pause;;
    esac
  done
}

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
    echo "6) Автоперезагрузка"
    echo "0) Выход"
    read -rp "Выбор > " choice || exit 0
    case "$choice" in
      1) add_one; pause;;
      2) list_instances; pause;;
      3) bulk_ops; pause;;
      4) instance_menu;;
      5) settings_menu;;
      6) auto_restart_menu;;
      0) exit 0;;
      *) warn "Неверный выбор"; pause;;
    esac
  done
}

# ========= ОБРАБОТКА АРГУМЕНТОВ КОМАНДНОЙ СТРОКИ =========
if [[ "${1:-}" == "--auto-restart" ]]; then
  auto_restart_all_containers
  exit 0
fi

main_menu
