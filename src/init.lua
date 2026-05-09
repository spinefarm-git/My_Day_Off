-----------------------------------------------------------------------
-- init.lua
--  - mydayoff-spinefarm 드라이버 엔트리 포인트
--  - 디바이스 생성/설정변경 라이프사이클 처리
--  - 매일 00:01 KST 자동 갱신 타이머
--  - 설정 웹서버 구동/종료
--  - switch 명령 처리 (사용자 입력 무시 → 즉시 재판정)
-----------------------------------------------------------------------

local Driver = require "st.driver"
local capabilities = require "st.capabilities"
local log = require "log"
local json = require "st.json"

local discovery         = require "discovery"
local common_web_server = require "common_web_server"
local html              = require "html"
local holiday_checker   = require "holiday_checker"
local commands          = require "command_handlers"

-----------------------------------------------------------------------
-- [0] 상수
-----------------------------------------------------------------------
local DEVICE_DNI = "mydayoff-spinefarm-01"

-- 매일 00:01 KST에 갱신
local REFRESH_HOUR   = 0    -- KST 0시
local REFRESH_MINUTE = 1    -- 1분 (00:01)

local statusMessage_cap = capabilities["achievedictionary39087.debugMessage"]

-----------------------------------------------------------------------
-- [1] 표준 emit_status 헬퍼
-----------------------------------------------------------------------
local function emit_status(device, msg)
  local comp = device.profile.components.status
  if comp and statusMessage_cap then
    local ok, err = pcall(function()
      device:emit_component_event(comp, statusMessage_cap.message({ value = msg }))
    end)
    if not ok then
      log.warn(string.format("[%s] emit_status 실패: %s", device.id, tostring(err)))
    end
  end
end

-----------------------------------------------------------------------
-- [2] 웹서버 로직
-----------------------------------------------------------------------

local function stop_web_server(device)
  local timer = device:get_field("server_timer")
  if timer then
    device.thread:cancel_timer(timer)
    device:set_field("server_timer", nil)
  end

  local socket_obj = device:get_field("server_socket")
  if socket_obj then
    socket_obj:close()
    device:set_field("server_socket", nil)
  end

  log.info("WEB_SERVER: Stopped")
end

-----------------------------------------------------------------------
-- 각 POST 저장 핸들러
-----------------------------------------------------------------------
local function save_api_key(driver, device, body)
  local raw = string.match(body or "", "apikey=([^&]*)")
  local val = common_web_server.url_decode(raw)
  if val and val ~= "" then
    device:set_field("api_key_public", val, { persist = true })
    log.info(string.format("[설정] 공공API 키 저장 (길이: %d)", #val))
    return true, "공공API 키 저장 완료"
  end
  return false, "API 키가 비어있습니다."
end

local function save_calendars(driver, device, body)
  local data, err = json.decode(body or "{}")
  if err or not data then
    return false, "JSON 파싱 오류: 데이터가 잘못되었습니다."
  end
  
  device:set_field("calendar_keyword", data.keyword or "", { persist = true })
  device:set_field("weekday_keyword", data.weekday_keyword or "", { persist = true })
  local cal_json = json.encode(data.calendars or {})
  device:set_field("calendars_data", cal_json, { persist = true })
  
  log.info("[설정] 등록된 캘린더 및 키워드 저장 완료 (휴일: " .. (data.keyword or "") .. ", 평일: " .. (data.weekday_keyword or "") .. ")")
  return true, "등록된 캘린더 설정 저장 완료"
end

local function save_detect_mode(driver, device, body)
  local raw = string.match(body or "", "mode=([^&]*)")
  local val = common_web_server.url_decode(raw)
  if val then
    device:set_field("holiday_detect_mode", val, { persist = true })
    log.info("[설정] 공휴일 판정 방식 저장: " .. val)
    return true, "판정 방식 저장 완료"
  end
  return false, "잘못된 데이터"
end

local function save_custom_dates(driver, device, body)
  local raw = string.match(body or "", "custom_dates=([^&]*)")
  local val = common_web_server.url_decode(raw)
  -- 빈 값도 저장 허용 (전체 삭제)
  device:set_field("custom_dates", val or "", { persist = true })
  log.info(string.format("[설정] 특정 날짜 저장: %s", val or "(비어있음)"))
  return true, "특정 날짜 목록 저장 완료"
end

local function save_weekdays(driver, device, body)
  -- 체크박스: weekday_1, weekday_2, ..., weekday_7
  -- 체크된 것만 POST body에 포함됨
  local selected = ""
  for n in string.gmatch("1234567", ".") do
    if string.find(body or "", "weekday_" .. n, 1, true) then
      selected = selected .. n
    end
  end
  -- 기본값은 없음(빈 문자열 허용), 사용자가 모든 요일을 해제할 수 있도록 함
  device:set_field("holiday_weekdays", selected, { persist = true })
  log.info("[설정] 요일 규칙 저장: " .. (selected == "" and "없음" or selected))
  return true, "요일 설정 저장 완료"
end

-----------------------------------------------------------------------
-- 웹 요청 처리 핸들러
-----------------------------------------------------------------------
local function handle_web_request(driver, device, method, path, headers, body)
  log.info(string.format("WEB_SERVER: %s %s", method, path))

  -- POST /save/apikey
  if method == "POST" and string.match(path, "^/save/apikey") then
    local ok, msg = save_api_key(driver, device, body)
    if ok then
      -- 저장 후 즉시 재판정
      device.thread:call_with_delay(0.5, function()
        local _, has_error = holiday_checker.refresh(driver, device)
        if has_error then commands.ping(nil, device) end
      end)
      return 200, "text/html", html.get_success_page(msg)
    else
      local data = {
        api_key_public = device:get_field("api_key_public"),
        calendar_keyword = device:get_field("calendar_keyword"),
        calendars_data  = device:get_field("calendars_data"),
        custom_dates    = device:get_field("custom_dates"),
        holiday_weekdays= device:get_field("holiday_weekdays"),
        expires_at      = device:get_field("web_server_expires_at")
      }
      return 200, "text/html", html.get_settings_page(data, { type = "error", msg = msg })
    end

  -- POST /save/calendars
  elseif method == "POST" and string.match(path, "^/save/calendars") then
    local ok, msg = save_calendars(driver, device, body)
    if ok then
      device.thread:call_with_delay(0.5, function()
        local _, has_error = holiday_checker.refresh(driver, device)
        if has_error then commands.ping(nil, device) end
      end)
      -- JSON response is simple here since client expects ok
      return 200, "application/json", '{"status":"ok"}'
    else
      return 400, "application/json", '{"status":"error","message":"' .. msg .. '"}'
    end

  -- POST /save/dates
  elseif method == "POST" and string.match(path, "^/save/dates") then
    local ok, msg = save_custom_dates(driver, device, body)
    device.thread:call_with_delay(0.5, function()
      holiday_checker.refresh(driver, device)
    end)
    return 200, "text/html", html.get_success_page(msg)

  -- POST /save/detect_mode
  elseif method == "POST" and string.match(path, "^/save/detect_mode") then
    local ok, msg = save_detect_mode(driver, device, body)
    device.thread:call_with_delay(0.5, function()
      holiday_checker.refresh(driver, device)
    end)
    return 200, "text/html", html.get_success_page(msg)

  -- POST /save/weekdays
  elseif method == "POST" and string.match(path, "^/save/weekdays") then
    local ok, msg = save_weekdays(driver, device, body)
    device.thread:call_with_delay(0.5, function()
      holiday_checker.refresh(driver, device)
    end)
    return 200, "text/html", html.get_success_page(msg)

  -- GET /success
  elseif method == "GET" and string.match(path, "^/success") then
    return 200, "text/html", html.get_success_page("달력 설정 저장 완료")

  -- GET / → 메인 설정 페이지
  else
    local data = {
      api_key_public  = device:get_field("api_key_public"),
      holiday_detect_mode = device:get_field("holiday_detect_mode") or "google",
      calendar_keyword = device:get_field("calendar_keyword"),
      weekday_keyword  = device:get_field("weekday_keyword"),
      calendars_data  = device:get_field("calendars_data") or "[]",
      custom_dates     = device:get_field("custom_dates"),
      holiday_weekdays = device:get_field("holiday_weekdays"),
      expires_at       = device:get_field("web_server_expires_at")
    }
    return 200, "text/html", html.get_settings_page(data)
  end
end

local function start_web_server(driver, device)
  stop_web_server(device)

  local request_processor = function(method, path, headers, body)
    return handle_web_request(driver, device, method, path, headers, body)
  end

  local ip, port, socket_obj = common_web_server.start(0, request_processor)

  if ip and port then
    device:set_field("server_socket", socket_obj)
    local url = string.format("http://%s:%d", ip, port)

    log.info("WEB_SERVER: 시작됨 -> " .. url)

    -- 상태 메시지에 웹서버 URL 표시
    local msg = "웹서버 실행 중: " .. url
    log.info(string.format("[%s] %s", device.id, msg))
    emit_status(device, msg)

    -- 1800초(30분) 후 자동 종료
    device:set_field("web_server_expires_at", os.time() + 1800)
    local timer = device.thread:call_with_delay(1800, function()
      log.info("WEB_SERVER: 30분 타임아웃 → 자동 종료")
      stop_web_server(device)
      emit_status(device, "웹서버 타임아웃으로 종료됨")
      -- 웹서버 종료 후 다시 날짜로 복원
      local _, has_error = holiday_checker.refresh(driver, device)
      if has_error then commands.ping(nil, device) end
    end)
    device:set_field("server_timer", timer)
    device:set_field("web_server_url", url)

    return true, url
  else
    log.error("WEB_SERVER: 시작 실패")
    emit_status(device, "웹서버 시작 실패")
    return false, nil
  end
end

-----------------------------------------------------------------------
-- [2] Ping 타이머 (10분 고정)
-----------------------------------------------------------------------
local HEALTH_CHECK_INTERVAL = 600

local function reschedule_health_check(driver, device)
  local old_timer = device:get_field("health_check_timer")
  if old_timer then
    device.thread:cancel_timer(old_timer)
    device:set_field("health_check_timer", nil)
  end

  local timer = device.thread:call_with_delay(HEALTH_CHECK_INTERVAL, function()
    local ok, err = pcall(function()
      commands.ping(driver, device)
    end)
    if not ok then
      log.error(string.format("[%s] ping 타이머 오류: %s", device.id, tostring(err)))
    end
    reschedule_health_check(driver, device)
  end)

  device:set_field("health_check_timer", timer)
  log.info(string.format("[%s] ping 타이머 설정: %d초 후", device.id, HEALTH_CHECK_INTERVAL))
end

-----------------------------------------------------------------------
-- [3] 자동 갱신 타이머 (매일 00:01 KST)
-----------------------------------------------------------------------
local function reschedule_daily_timer(device, driver)
  -- 기존 타이머 취소
  local old_timer = device:get_field("DailyTimer")
  if old_timer then
    device.thread:cancel_timer(old_timer)
    device:set_field("DailyTimer", nil)
  end

  -- 다음 00:01 KST까지 남은 초 계산 (단순화)
  local now_kst = os.time() + (9 * 3600)
  local t = os.date("*t", now_kst)

  local target_hour = REFRESH_HOUR
  local target_min  = REFRESH_MINUTE

  -- 현재 KST에서 자정 기준 경과 초
  local elapsed_today = t.hour * 3600 + t.min * 60 + t.sec
  local target_secs = target_hour * 3600 + target_min * 60

  local seconds_until
  if target_secs > elapsed_today then
    seconds_until = target_secs - elapsed_today
  else
    -- 이미 지났으면 내일 같은 시각
    seconds_until = (86400 - elapsed_today) + target_secs
  end

  log.info(string.format("[타이머] 다음 갱신: %d초 후 (%02d:%02d KST)",
    seconds_until, target_hour, target_min))

  local timer = device.thread:call_with_delay(seconds_until, function()
    log.info("[타이머] 일일 자동 갱신 실행 (디버그 날짜 초기화)")

    device:set_field("debug_date", "", { persist = true })

    local ok, err = pcall(function()
      local _, has_error = holiday_checker.refresh(driver, device)
      if has_error then commands.ping(nil, device) end
    end)
    if not ok then
      log.error("[타이머] 판정 오류: " .. tostring(err))
    end
    reschedule_daily_timer(device, driver)
  end)

  device:set_field("DailyTimer", timer)
end

-----------------------------------------------------------------------
-- [3] 디바이스 라이프사이클 핸들러
-----------------------------------------------------------------------

local function device_removed(driver, device)
  local daily = device:get_field("DailyTimer")
  if daily then device.thread:cancel_timer(daily) end
  local srv = device:get_field("server_timer")
  if srv then device.thread:cancel_timer(srv) end
  local health_timer = device:get_field("health_check_timer")
  if health_timer then device.thread:cancel_timer(health_timer) end
end

local function device_init(driver, device)
  log.info(string.format("[%s] 기기 초기화 (DNI: %s)", device.id, tostring(device.device_network_id)))

  -- 즉시 1회 판정 실행
  device.thread:call_with_delay(2, function()
    local ok, err = pcall(function()
      local _, has_error = holiday_checker.refresh(driver, device)
      if has_error then commands.ping(nil, device) end
    end)
    if not ok then
      log.warn("[init] 초기 판정 오류: " .. tostring(err))
    end
  end)

  -- 매일 00:00 타이머 설정
  reschedule_daily_timer(device, driver)

  -- ping 타이머 설정 (10분 주기)
  reschedule_health_check(driver, device)
end

local function device_info_changed(driver, device, event, args)
  log.info(string.format("[%s] 설정 변경됨", device.id))

  local old_prefs = args.old_st_store and args.old_st_store.preferences or {}

  -- 웹서버 토글
  local old_start = old_prefs.startWebServer or false
  local new_start = device.preferences.startWebServer or false

  if new_start and not old_start then
    log.info("[웹서버] 실행 트리거")
    local ok, url = start_web_server(driver, device)
    if ok then
      -- switch의 label을 URL로 표시할 수 없으므로 로그 확인
      log.info("[웹서버] URL: " .. tostring(url))
    end

  elseif not new_start and old_start then
    log.info("[웹서버] 중지 트리거")
    stop_web_server(device)
    emit_status(device, "웹서버 수동 종료됨")
    device:set_field("web_server_url", nil)
  end

  -- 동일 디바이스 추가 체크
  local old_add = old_prefs.addSameDevice or false
  local new_add = device.preferences.addSameDevice or false
  if new_add and not old_add then
    log.info("[설정] 동일 디바이스 추가 요청")
    
    -- 다음 사용 가능한 번호 찾기 (02, 03, ...)
    local max_num = 1
    for _, d in ipairs(driver:get_devices()) do
      local num = (d.device_network_id or ""):match("-0?(%d+)$")
      if num then
        local n = tonumber(num)
        if n and n > max_num then max_num = n end
      end
    end
    local next_num = max_num + 1
    local next_dni = string.format("mydayoff-spinefarm-%02d", next_num)
    local next_label = string.format("My Day Off Spinefarm (Copy %d)", next_num - 1)

    emit_status(device, string.format("Copy %d 장치 생성 요청됨", next_num - 1))
    device.thread:call_with_delay(1, function()
      log.info(string.format("[설정] 신규 디바이스 생성 시도: %s", next_dni))
      driver:try_create_device({
        type = "LAN",
        device_network_id = next_dni,
        label = next_label,
        profile = "my-day-off-main",
        manufacturer = "SmartThings",
        model = "v1",
        vendor_provided_label = "Virtual"
      })
    end)
  end

  -- proxyUrl 변경 시 즉시 재판정
  local old_proxy = old_prefs.proxyUrl or ""
  local new_proxy = device.preferences.proxyUrl or ""
  if new_proxy ~= old_proxy then
    log.info("[설정] proxyUrl 변경 감지")
  end

  -- 설정 변경 후 즉시 재판정
  device.thread:call_with_delay(1, function()
    local ok, err = pcall(function()
      local _, has_error = holiday_checker.refresh(driver, device)
      if has_error then commands.ping(nil, device) end
    end)
    if not ok then
      log.warn("[infoChanged] 재판정 오류: " .. tostring(err))
    end
    reschedule_daily_timer(device, driver)
  end)
end

-----------------------------------------------------------------------
-- [4] Debug Date 핸들러 (DEBUG UI 숨김 - 프로필에서 제거됨, 복원 시 주석 해제)
-----------------------------------------------------------------------
-- local function handle_debug_set_date(driver, device, command)
--   ...
-- end

-----------------------------------------------------------------------
-- [5] 드라이버 정의 및 실행
-----------------------------------------------------------------------
local mydayoff_driver = Driver("my-day-off", {
  discovery = discovery.handle_discovery,

  lifecycle_handlers = {
    init        = device_init,
    removed     = device_removed,
    infoChanged = device_info_changed,
  },

  capability_handlers = {
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = commands.momentary_push,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = commands.refresh,
    },
    [capabilities.healthCheck.ID] = {
      [capabilities.healthCheck.commands.ping.NAME] = commands.ping,
    },
  }
})

mydayoff_driver:run()
