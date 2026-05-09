-----------------------------------------------------------------------
-- command_handlers.lua
--  - mydayoff-spinefarm capability 핸들러
--  - ping: Edge Bridge 연결 확인 (online/offline 보고)
--  - refresh: 수동 갱신
--  - momentary_push: 휴일/평일 강제 전환
-----------------------------------------------------------------------

local capabilities    = require "st.capabilities"
local log             = require "log"
local json            = require "st.json"
local holiday_checker = require "holiday_checker"

local commands = {}

local statusMessage_cap = capabilities["achievedictionary39087.debugMessage"]

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
-- [1] Health Check (healthCheck.ping 커맨드 핸들러 + ping 타이머 콜백)
-----------------------------------------------------------------------
function commands.ping(_, device)
  local cosock = require "cosock"
  local http   = cosock.asyncify "socket.http"
  local ltn12  = require "ltn12"

  local proxy_url = device.preferences.proxyUrl
  if not proxy_url or proxy_url == "" then
    log.warn("[ping] proxyUrl 미설정")
    emit_status(device, "연결 실패 — proxyUrl을 설정해주세요")
    device:offline()
    return
  end

  local url = proxy_url:gsub("/+$", "") .. "/api/ping"
  local resp_chunks = {}
  local code
  local ok, err = pcall(function()
    local _, c = http.request({
      url     = url,
      method  = "POST",
      source  = ltn12.source.string(""),
      headers = { ["content-length"] = "0" },
      sink    = ltn12.sink.table(resp_chunks),
      timeout = 10,
    })
    code = c
  end)

  if ok and tonumber(code) == 200 then
    log.info("[ping] EB OK → online")
    device:online()
  else
    log.warn("[ping] EB 응답 없음: " .. tostring(ok and code or err))
    emit_status(device, "연결 실패 — Edge Bridge를 확인해주세요")
    device:offline()
  end
end

-----------------------------------------------------------------------
-- [2] Refresh (수동 갱신)
-----------------------------------------------------------------------
function commands.refresh(driver, device)
  log.info("[refresh] 수동 갱신 요청 - 디버그 날짜 초기화")

  device:set_field("debug_date", "", { persist = true })
  holiday_checker.emit_loading(device)

  device.thread:call_with_delay(0.5, function()
    local ok, err = pcall(function()
      local _, has_error = holiday_checker.refresh(driver, device)
      if has_error then
        commands.ping(nil, device)
      end
    end)
    if not ok then
      log.error("[refresh] 오류: " .. tostring(err))
    end
    device:set_field("is_refreshing", false)
  end)
end

-----------------------------------------------------------------------
-- [3] Momentary (휴일/평일 강제 전환)
-----------------------------------------------------------------------
function commands.momentary_push(_, device, _)
  log.info("[momentary] 버튼 눌림 - 즉시 토글")

  local status_cap = capabilities["achievedictionary39087.myDayOffStatus"]
  local main_comp  = device.profile.components.main

  local current_val = device:get_field("last_evaluated_holiday")
  if current_val == nil then current_val = false end

  local new_val = not current_val
  local new_str = new_val and "휴일" or "평일"
  log.info("[momentary] 토글: " .. tostring(current_val) .. " -> " .. tostring(new_val) .. " (" .. new_str .. ")")

  local today = holiday_checker.get_effective_today(device)
  local ok_e, new_override = pcall(json.encode, { ymd = today.ymd, is_holiday = new_val })
  if ok_e then
    device:set_field("manual_override", new_override, { persist = true })
  end

  device:set_field("last_evaluated_holiday", new_val)

  if main_comp and status_cap then
    pcall(function()
      device:emit_component_event(main_comp, status_cap.holiday({ value = new_str }))
    end)
  end

  pcall(function()
    local toggle_comp = device.profile.components.toggle
    if toggle_comp then
      device:emit_component_event(toggle_comp, capabilities.momentary.push())
    end
  end)

  log.info("[momentary] 완료")
end

return commands
