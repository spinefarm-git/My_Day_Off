-----------------------------------------------------------------------
-- ical_parser.lua
--  - 등록된 캘린더 iCal (.ics) 피드 다운로드 및 파싱
--  - 복수 캘린더 처리 및 키워드 기반 필터링
--  - Edge Bridge를 통해 HTTPS 요청
-----------------------------------------------------------------------

local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local log = require "log"
local json = require "st.json"

local ical_parser = {}

-----------------------------------------------------------------------
-- [Helper] iCal 날짜 문자열 → YYYYMMDD 숫자
-----------------------------------------------------------------------
local function parse_ical_date(s)
  if not s then return nil end
  local date_part = string.match(s, "^(%d%d%d%d%d%d%d%d)")
  return date_part
end

local function extract_date_from_line(line)
  local val = string.match(line, ":(.+)$")
  return parse_ical_date(val)
end

local function unescape_ical(text)
  if not text then return nil end
  text = string.gsub(text, "\\,", ",")
  text = string.gsub(text, "\\;", ";")
  text = string.gsub(text, "\\n", " ")
  text = string.gsub(text, "\\N", " ")
  text = string.gsub(text, "\\\\", "\\")
  return text
end

-----------------------------------------------------------------------
-- [Core] iCal 데이터 파싱
--  - 오늘 날짜(YYYYMMDD)를 포함하는 VEVENT 중 키워드 일치 항목 찾기
-----------------------------------------------------------------------
function ical_parser.parse(ics_text, today_ymd, keyword, weekday_keyword)
  if not ics_text or #ics_text == 0 then
    return {}
  end

  local events = {}
  local in_event = false
  local dtstart = nil
  local dtend = nil
  local summary = nil
  local description = nil

  -- 줄 이음 처리
  local unfolded = string.gsub(ics_text, "\r\n[ \t]", "")
  unfolded = string.gsub(unfolded, "\n[ \t]", "")

  for line in string.gmatch(unfolded, "[^\r\n]+") do
    if string.match(line, "^BEGIN:VEVENT") then
      in_event = true
      dtstart = nil
      dtend = nil
      summary = nil
      description = nil

    elseif string.match(line, "^END:VEVENT") then
      if in_event and dtstart then
        -- dtstart는 YYYYMMDD 또는 YYYYMMDDTHHMMSSZ 형식
        local start_ymd = dtstart:sub(1, 8)
        local end_ymd = dtend and dtend:sub(1, 8) or start_ymd
        
        if start_ymd == today_ymd or (dtend and today_ymd >= start_ymd and today_ymd < end_ymd) then
           table.insert(events, {
             summary = summary or "",
             description = description or ""
           })
        end
      end
      in_event = false

    elseif in_event then
      if string.match(line, "^DTSTART") then
        dtstart = extract_date_from_line(line)
      elseif string.match(line, "^DTEND") then
        dtend = extract_date_from_line(line)
      elseif string.match(line, "^SUMMARY") then
        summary = string.match(line, ":(.+)$")
        summary = unescape_ical(summary)
      elseif string.match(line, "^DESCRIPTION") then
        description = string.match(line, ":(.+)$")
        description = unescape_ical(description)
      end
    end
  end

  return events
end

-----------------------------------------------------------------------
-- [Core] 복수 캘린더 순회하며 오늘 휴일 여부 판정
-----------------------------------------------------------------------
function ical_parser.check_today(device, today_ymd)
  local cals_raw = device:get_field("calendars_data")
  local calendars = {}
  if cals_raw and cals_raw ~= "" then
    calendars = json.decode(cals_raw) or {}
  end

  local proxy_url = device.preferences.proxyUrl
  if not proxy_url or proxy_url == "" then
    return {}, {}, "proxyUrl 미설정"
  end
  local proxy_base = proxy_url:gsub("/+$", "")

  local user_events = {}
  local google_events = {}
  local any_error = nil

  -- 1. 사용자 등록 캘린더
  for _, cal in ipairs(calendars) do
    if cal.url and cal.url ~= "" then
      local proxy_request_url = proxy_base .. "/api/forward?url=" .. cal.url
      log.info(string.format("[iCal] 다운로드 시작: %s", cal.name))

      local resp_chunks = {}
      local ok, code = pcall(function()
        local _, c = http.request({
          url = proxy_request_url, method = "GET",
          sink = ltn12.sink.table(resp_chunks), timeout = 8
        })
        return c
      end)

      if ok and code and tonumber(code) == 200 then
        local ics_text = table.concat(resp_chunks)
        local events = ical_parser.parse(ics_text, today_ymd)
        for _, ev in ipairs(events) do
          table.insert(user_events, ev)
        end
      else
        log.warn(string.format("[iCal] %s 로드 실패 (HTTP %s)", cal.name, tostring(code)))
        any_error = any_error or string.format("%s 로드 실패", cal.name)
      end
    end
  end

  -- 2. 구글 공휴일 캘린더 (설정된 경우)
  local detect_mode = device:get_field("holiday_detect_mode") or "google"
  if detect_mode == "google" then
    local google_url = "https://calendar.google.com/calendar/ical/ko.south_korea%23holiday%40group.v.calendar.google.com/public/basic.ics"
    local proxy_request_url = proxy_base .. "/api/forward?url=" .. google_url
    log.info("[iCal] 구글 공휴일 캘린더 다운로드")

    local resp_chunks = {}
    local ok, code = pcall(function()
      local _, c = http.request({
        url = proxy_request_url, method = "GET",
        sink = ltn12.sink.table(resp_chunks), timeout = 8
      })
      return c
    end)

    if ok and code and tonumber(code) == 200 then
      local ics_text = table.concat(resp_chunks)
      local events = ical_parser.parse(ics_text, today_ymd)
      for _, ev in ipairs(events) do
        table.insert(google_events, ev)
      end
    else
      log.warn("[iCal] 구글 공휴일 로드 실패")
      any_error = any_error or "구글 공휴일 로드 실패"
    end
  end

  return user_events, google_events, any_error
end

return ical_parser
