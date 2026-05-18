-----------------------------------------------------------------------
-- holiday_checker.lua
--  - 4가지 판정 로직 통합
--  - 결과를 ST capability attribute로 emit
--  - debug_date 필드로 조회 날짜 override 가능
-----------------------------------------------------------------------

local capabilities = require "st.capabilities"
local log = require "log"

local public_api  = require "public_api"
local ical_parser = require "ical_parser"
local json        = require "st.json"

local checker = {}

-- Capabilities
-- local debug_date_cap = capabilities["achievedictionary39087.debugDate"]  -- [DEBUG UI 숨김]
local statusMessage_cap = capabilities["achievedictionary39087.debugMessage"]
local cardMessage_cap   = capabilities["achievedictionary39087.cardMessage"]
local status_cap        = capabilities["achievedictionary39087.myDayOffStatus"]
local details_cap       = capabilities["achievedictionary39087.myDayOffDetails"]

local function emit_card(device, msg)
  local comp = device.profile.components.main
  if comp and cardMessage_cap then
    pcall(function()
      device:emit_component_event(comp, cardMessage_cap.message({ value = msg }))
    end)
  end
end

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

-- 요일 이름 (wday: 1=일 ~ 7=토)
local WDAY_NAMES = { "일", "월", "화", "수", "목", "금", "토" }

-----------------------------------------------------------------------
-- [Helper] wday 계산
-----------------------------------------------------------------------
local function calc_wday(year, month, day)
  local t = os.date("*t", os.time({
    year = year, month = month, day = day,
    hour = 12, min = 0, sec = 0, isdst = false
  }))
  return t.wday
end

-----------------------------------------------------------------------
-- [Helper] 유효 날짜 구조체 반환
-----------------------------------------------------------------------
function checker.get_effective_today(device)
  local debug_raw = device:get_field("debug_date") or ""
  debug_raw = debug_raw:match("^%s*(.-)%s*$")

  if debug_raw ~= "" then
    local m, d = debug_raw:match("^(%d%d?)/(%d%d?)$")
    if m and d then
      local now_kst = os.time() + (9 * 3600)
      local cur = os.date("*t", now_kst)
      local mn, dn = tonumber(m), tonumber(d)
      local yn = cur.year
      local wday = calc_wday(yn, mn, dn)
      return {
        year  = yn, month = mn, day = dn,
        ymd   = string.format("%04d%02d%02d", yn, mn, dn),
        md    = string.format("%02d/%02d", mn, dn),
        wday  = wday,
        display = string.format("[T] %d/%d (%s)", mn, dn, WDAY_NAMES[wday] or "?"),
        is_debug = true,
      }
    else
      log.warn("[날짜] debug_date 형식 오류: '" .. debug_raw .. "' (예: 4/24)")
    end
  end

  local offset = tonumber(device.preferences and device.preferences.dateOffset) or 0
  local now_kst = os.time() + (9 * 3600) + (offset * 86400)
  local t = os.date("*t", now_kst)
  local prefix = (offset > 0) and string.format("[+%d] ", offset) or ""
  return {
    year  = t.year, month = t.month, day = t.day,
    ymd   = string.format("%04d%02d%02d", t.year, t.month, t.day),
    md    = string.format("%02d/%02d", t.month, t.day),
    wday  = t.wday,
    display = string.format("%s%d/%d (%s)", prefix, t.month, t.day, WDAY_NAMES[t.wday] or "?"),
    is_debug = false,
  }
end

-----------------------------------------------------------------------
-- [Helper] 내일 날짜 구조체 반환 (dateOffset + 1)
-----------------------------------------------------------------------
local function get_tomorrow(device)
  local offset = tonumber(device.preferences and device.preferences.dateOffset) or 0
  local now_kst = os.time() + (9 * 3600) + ((offset + 1) * 86400)
  local t = os.date("*t", now_kst)
  return {
    year    = t.year, month = t.month, day = t.day,
    ymd     = string.format("%04d%02d%02d", t.year, t.month, t.day),
    md      = string.format("%02d/%02d", t.month, t.day),
    wday    = t.wday,
    display = string.format("[+%d] %d/%d (%s)", offset + 1, t.month, t.day, WDAY_NAMES[t.wday] or "?"),
  }
end

-----------------------------------------------------------------------
-- [판정단]
-----------------------------------------------------------------------
local function check_public_holiday(device, today, pub_items)
  local is_hol, hol_name, api_err
  local ok, err_msg = pcall(function()
    if pub_items then
      is_hol, hol_name, api_err = public_api.check_date_from_items(pub_items, today.ymd)
    else
      is_hol, hol_name, api_err = public_api.check_today(device, today)
    end
  end)

  local api_key = device:get_field("api_key_public")
  local reg = (api_key and api_key ~= "") and "등록" or "미설정"

  if not ok then return false, "오류", tostring(err_msg), reg end
  if api_err then return false, "오류", api_err, reg end
  if is_hol then
    return true, "휴일", tostring(hol_name), reg
  elseif hol_name then
    return false, "평일", tostring(hol_name), reg
  end
  return false, "평일", "해당없음", reg
end

local function check_calendar_holiday(device, today_ymd, raw_ical)
  local detect_mode = device:get_field("holiday_detect_mode") or "google"
  local user_events, google_events, cal_err
  if raw_ical then
    user_events, google_events, cal_err = ical_parser.parse_from_raw(raw_ical, today_ymd)
  else
    user_events, google_events, cal_err = ical_parser.check_today(device, today_ymd)
  end
  
  local holiday_keywords = device:get_field("calendar_keyword") or ""
  local weekday_keywords = device:get_field("weekday_keyword") or ""

  -- [1] 구글 공휴일 해석 (Official Holiday 용)
  local google_is_hol = false
  local google_hol_desc = "일정없음"
  if #google_events > 0 then
    local names = {}
    for _, ev in ipairs(google_events) do
      table.insert(names, ev.summary)
      local d_lw = string.lower(ev.description)
      if string.find(d_lw, "공휴일", 1, true) or string.find(d_lw, "public holiday", 1, true) then
        google_is_hol = true
      end
    end
    if #names > 0 then google_hol_desc = table.concat(names, ", ") end
  end

  -- [2] 사용자 등록 캘린더 해석 (User Calendar 용)
  local user_is_hol = false
  local user_hol_desc = "일정없음"
  local is_forced_weekday = false
  local forced_desc = ""

  if #user_events > 0 then
    local names = {}
    for _, ev in ipairs(user_events) do
      local s_lw = string.lower(ev.summary)
      local d_lw = string.lower(ev.description)

      -- 강제 평일 체크
      local weekday_keywords_val = device:get_field("weekday_keyword") or ""
      if weekday_keywords_val ~= "" then
        for kw_p in string.gmatch(weekday_keywords_val, "([^,]+)") do
          local kw = string.lower(kw_p:match("^%s*(.-)%s*$"))
          if kw ~= "" and (string.find(s_lw, kw, 1, true) or string.find(d_lw, kw, 1, true)) then
            is_forced_weekday = true
            forced_desc = ev.summary
            break
          end
        end
      end

      -- 휴일 키워드 체크
      if holiday_keywords ~= "" then
        for kw_p in string.gmatch(holiday_keywords, "([^,]+)") do
          local kw = string.lower(kw_p:match("^%s*(.-)%s*$"))
          if kw ~= "" and (string.find(s_lw, kw, 1, true) or string.find(d_lw, kw, 1, true)) then
            user_is_hol = true
            table.insert(names, ev.summary)
            break
          end
        end
      end
    end
    if #names > 0 then user_hol_desc = table.concat(names, ", ") end
  end

  -- 사용자 캘린더 등록 개수 계산
  local cals_raw = device:get_field("calendars_data") or "[]"
  local _, count = string.gsub(cals_raw, '{"name":', "")
  local reg_user = (count > 0) and string.format("등록(%d)", count) or "미등록"

  return {
    google_is_hol = google_is_hol,
    google_hol_desc = google_hol_desc,
    user_is_hol = user_is_hol,
    user_hol_desc = user_hol_desc,
    is_forced_weekday = is_forced_weekday,
    forced_desc = forced_desc,
    reg_user = reg_user,
    cal_err = cal_err
  }
end

local function check_custom_dates(device, today_md)
  local raw = device:get_field("custom_dates") or ""
  local reg = "미설정"

  if raw ~= "" then
    local count = 0
    for _ in string.gmatch(raw, "([^,]+)") do count = count + 1 end
    if count > 0 then reg = string.format("등록(%d)", count) end
  end

  if raw == "" then return false, "평일", "해당없음", reg end

  for entry in string.gmatch(raw, "([^,]+)") do
    entry = entry:match("^%s*(.-)%s*$")
    local date_part = string.match(entry, "^(%d%d/%d%d)")
    local memo_part = string.match(entry, "^%d%d/%d%d=(.+)$") or ""

    if date_part == today_md then
      local label = memo_part ~= "" and memo_part or "지정날짜"
      return true, "휴일", label, reg
    end
  end
  return false, "평일", "해당없음", reg
end

local function check_weekday_rule(device, today_wday)
  local raw = device:get_field("holiday_weekdays") or "17"
  local reg = "사용안함"

  if raw ~= "" then
    local count = #raw
    if count > 0 then reg = string.format("등록(%d)", count) end
  end

  local wday_str = tostring(today_wday)
  local day_name = WDAY_NAMES[today_wday] or "?"

  if string.find(raw, wday_str, 1, true) then
    return true, "휴일", day_name .. "요일", reg
  else
    return false, "평일", day_name .. "요일", reg
  end
end

-----------------------------------------------------------------------
-- [Core] 휴일 판정 통합 실행 + ST emit
-----------------------------------------------------------------------
function checker.refresh(driver, device)
  local today = checker.get_effective_today(device)
  log.info(string.format("[휴일판정] 기준날짜: %s - %s", today.ymd, today.display))

  -- [DEBUG UI 숨김] debugDate capability emit 비활성화 (프로필에서 제거됨, 기능은 유지)
  -- local status_comp = device.profile.components.status
  -- if status_comp and debug_date_cap then
  --   pcall(function()
  --     local stored = device:get_field("debug_date") or ""
  --     device:emit_component_event(status_comp, debug_date_cap.date({ value = stored }))
  --   end)
  -- end

  local detect_mode = device:get_field("holiday_detect_mode") or "google"
  local mode_name = (detect_mode == "public") and "공공 API" or (detect_mode == "google" and "구글" or "미사용")

  -- iCal 다운로드 1회 (오늘/내일 파싱에 공유)
  local raw_ical = ical_parser.download_raw(device)

  -- 공공 API 월 데이터 선행 조회 (오늘/내일 재사용, 월 경계 시 2회)
  local pub_items_today, pub_items_tmr
  if detect_mode == "public" then
    pub_items_today = public_api.fetch_month(device, today.year, today.month)
    local tmr = get_tomorrow(device)
    if tmr.year == today.year and tmr.month == today.month then
      pub_items_tmr = pub_items_today
    else
      pub_items_tmr = public_api.fetch_month(device, tmr.year, tmr.month)
    end
  end

  -- 판정 시작
  local res_cal = check_calendar_holiday(device, today.ymd, raw_ical)

  -- ① 공휴일 (Public or Google)
  local hol1, jdg1, dtl1, reg1 = false, "평일", "미사용", mode_name
  if detect_mode == "public" then
    hol1, jdg1, dtl1, _ = check_public_holiday(device, today, pub_items_today)
    if jdg1 == "오류" then
      log.warn(string.format("[휴일판정] 공공 API 오류: %s", dtl1))
      emit_status(device, "공공 API 오류: " .. dtl1)
      dtl1 = "-"
    end
  elseif detect_mode == "google" then
    if res_cal.cal_err then
      jdg1 = "오류"
      dtl1 = "-"
    else
      hol1 = res_cal.google_is_hol
      jdg1 = hol1 and "휴일" or "평일"
      dtl1 = res_cal.google_hol_desc
    end
  else
    jdg1, dtl1 = "-", "-"
  end

  -- ② 사용자 캘린더
  local hol2 = res_cal.user_is_hol
  local jdg2 = hol2 and "휴일" or "평일"
  local dtl2 = res_cal.user_is_hol and res_cal.user_hol_desc or "일정없음"
  local reg2 = res_cal.reg_user

  if res_cal.cal_err then
    log.warn(string.format("[휴일판정] 캘린더 오류: %s", res_cal.cal_err))
    emit_status(device, "캘린더 오류: " .. res_cal.cal_err)
    jdg2 = "오류"
    dtl2 = "-"
  end

  -- ③ 기타 규칙
  local hol3, jdg3, dtl3, reg3 = check_custom_dates(device, today.md)
  local hol4, jdg4, dtl4, reg4 = check_weekday_rule(device, today.wday)

  -- 우선순위: 평일(F) > 휴일 > 평일
  local is_holiday
  local final_status_str

  if res_cal.is_forced_weekday then
    log.info("[휴일판정] 강제 평일 키워드 발견: " .. res_cal.forced_desc)
    is_holiday = false
    final_status_str = "평일"
    jdg2 = "평일(F)"
    dtl2 = res_cal.forced_desc
  else
    is_holiday = hol1 or hol2 or hol3 or hol4
    final_status_str = is_holiday and "휴일" or "평일"

    -- 매뉴얼 오버라이드 확인
    local over_json = device:get_field("manual_override") or ""
    if over_json ~= "" then
      local ok, over = pcall(json.decode, over_json)
      if ok and over then
        if over.ymd == today.ymd then
          log.info("[휴일판정] 매뉴얼 오버라이드 적용됨! 원래: " .. tostring(is_holiday) .. " -> 강제: " .. tostring(over.is_holiday))
          is_holiday = over.is_holiday
          final_status_str = is_holiday and "휴일" or "평일"
        else
          device:set_field("manual_override", "", {persist = true})
        end
      end
    end
  end

  -- Emit myDayOffDetails
  local main_comp = device.profile.components.main
  if main_comp and details_cap then
    pcall(function()
      device:emit_component_event(main_comp, details_cap.publicReg({ value = reg1 }))
      device:emit_component_event(main_comp, details_cap.publicHol({ value = jdg1 }))
      device:emit_component_event(main_comp, details_cap.publicDet({ value = dtl1 }))

      device:emit_component_event(main_comp, details_cap.calReg({ value = reg2 }))
      device:emit_component_event(main_comp, details_cap.calHol({ value = jdg2 }))
      device:emit_component_event(main_comp, details_cap.calDet({ value = dtl2 }))

      device:emit_component_event(main_comp, details_cap.customReg({ value = reg3 }))
      device:emit_component_event(main_comp, details_cap.customHol({ value = jdg3 }))
      device:emit_component_event(main_comp, details_cap.customDet({ value = dtl3 }))

      device:emit_component_event(main_comp, details_cap.weekdayReg({ value = reg4 }))
      device:emit_component_event(main_comp, details_cap.weekdayHol({ value = jdg4 }))
      device:emit_component_event(main_comp, details_cap.weekdayDet({ value = dtl4 }))
    end)
  end

  -- Emit myDayOffStatus
  if main_comp and status_cap then
    pcall(function()
      device:emit_component_event(main_comp, status_cap.todayDate({ value = today.display }))
    end)
    pcall(function()
      device:emit_component_event(main_comp, status_cap.holiday({ value = final_status_str }))
    end)
  end

  device:set_field("last_evaluated_holiday", is_holiday)

  local has_error = (res_cal.cal_err ~= nil) or (detect_mode == "public" and jdg1 == "오류")

  -- 오류가 없을 때만 성공 상태 emit (오류 시 위에서 이미 emit됨)
  if not has_error then
    local card_msg = string.format("%s : %s", today.display, final_status_str)
    emit_card(device, card_msg)
  end

  checker.refresh_tomorrow(driver, device, raw_ical, pub_items_tmr)

  return is_holiday, has_error
end

-----------------------------------------------------------------------
-- [Core] 내일 휴일 판정 + tomorrow 컴포넌트 emit
-----------------------------------------------------------------------
function checker.refresh_tomorrow(driver, device, raw_ical, pub_items_tmr)
  local tmr_comp = device.profile.components.tomorrow
  if not tmr_comp then return end

  local tomorrow = get_tomorrow(device)
  log.info(string.format("[내일판정] 기준날짜: %s - %s", tomorrow.ymd, tomorrow.display))

  local detect_mode = device:get_field("holiday_detect_mode") or "google"
  local mode_name = (detect_mode == "public") and "공공 API" or (detect_mode == "google" and "구글" or "미사용")

  local res_cal = check_calendar_holiday(device, tomorrow.ymd, raw_ical)

  -- ① 공휴일 (Public or Google)
  local hol1, jdg1, dtl1, reg1 = false, "평일", "미사용", mode_name
  if detect_mode == "public" then
    hol1, jdg1, dtl1, _ = check_public_holiday(device, tomorrow, pub_items_tmr)
    if jdg1 == "오류" then
      log.warn(string.format("[내일판정] 공공 API 오류: %s", dtl1))
      dtl1 = "-"
    end
  elseif detect_mode == "google" then
    if res_cal.cal_err then
      jdg1 = "오류"
      dtl1 = "-"
    else
      hol1 = res_cal.google_is_hol
      jdg1 = hol1 and "휴일" or "평일"
      dtl1 = res_cal.google_hol_desc
    end
  else
    jdg1, dtl1 = "-", "-"
  end

  -- ② 사용자 캘린더
  local hol2 = res_cal.user_is_hol
  local jdg2 = hol2 and "휴일" or "평일"
  local dtl2 = hol2 and res_cal.user_hol_desc or "일정없음"
  local reg2 = res_cal.reg_user
  if res_cal.cal_err then
    jdg2 = "오류"
    dtl2 = "-"
  end

  -- ③ 기타 규칙
  local hol3, jdg3, dtl3, reg3 = check_custom_dates(device, tomorrow.md)
  local hol4, jdg4, dtl4, reg4 = check_weekday_rule(device, tomorrow.wday)

  -- 최종 판정 (매뉴얼 오버라이드 미적용)
  local is_holiday, final_str
  if res_cal.is_forced_weekday then
    is_holiday = false
    final_str = "평일"
    jdg2 = "평일(F)"
    dtl2 = res_cal.forced_desc
  else
    is_holiday = hol1 or hol2 or hol3 or hol4
    final_str = is_holiday and "휴일" or "평일"
  end

  -- Emit myDayOffDetails
  if details_cap then
    pcall(function()
      device:emit_component_event(tmr_comp, details_cap.publicReg({ value = reg1 }))
      device:emit_component_event(tmr_comp, details_cap.publicHol({ value = jdg1 }))
      device:emit_component_event(tmr_comp, details_cap.publicDet({ value = dtl1 }))

      device:emit_component_event(tmr_comp, details_cap.calReg({ value = reg2 }))
      device:emit_component_event(tmr_comp, details_cap.calHol({ value = jdg2 }))
      device:emit_component_event(tmr_comp, details_cap.calDet({ value = dtl2 }))

      device:emit_component_event(tmr_comp, details_cap.customReg({ value = reg3 }))
      device:emit_component_event(tmr_comp, details_cap.customHol({ value = jdg3 }))
      device:emit_component_event(tmr_comp, details_cap.customDet({ value = dtl3 }))

      device:emit_component_event(tmr_comp, details_cap.weekdayReg({ value = reg4 }))
      device:emit_component_event(tmr_comp, details_cap.weekdayHol({ value = jdg4 }))
      device:emit_component_event(tmr_comp, details_cap.weekdayDet({ value = dtl4 }))
    end)
  end

  -- Emit myDayOffStatus
  if status_cap then
    pcall(function()
      device:emit_component_event(tmr_comp, status_cap.todayDate({ value = tomorrow.display }))
    end)
    pcall(function()
      device:emit_component_event(tmr_comp, status_cap.holiday({ value = final_str }))
    end)
  end
end

-----------------------------------------------------------------------
-- [Helper] 강제 조회/오버라이드 시 로딩 표시
-----------------------------------------------------------------------
function checker.emit_loading(device)
  local loading_cap = capabilities["achievedictionary39087.myDayOffStatus"]
  if not loading_cap then return end

  local main_comp = device.profile.components.main
  if main_comp then
    pcall(function()
      device:emit_component_event(main_comp, loading_cap.todayDate({ value = "조회중..." }))
    end)
  end

  local tmr_comp = device.profile.components.tomorrow
  if tmr_comp then
    pcall(function()
      device:emit_component_event(tmr_comp, loading_cap.todayDate({ value = "조회중..." }))
    end)
  end
end

return checker
