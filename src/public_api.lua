-----------------------------------------------------------------------
-- public_api.lua
--  - 한국천문연구원_특일정보 (data.go.kr) API 호출
--  - 오늘 날짜가 법정 공휴일인지 확인
-----------------------------------------------------------------------

local cosock = require "cosock"
local http = cosock.asyncify "socket.http"
local ltn12 = require "ltn12"
local log = require "log"

local public_api = {}

local BASE_URL = "http://apis.data.go.kr/B090041/openapi/service/SpcdeInfoService/getHoliDeInfo"

-----------------------------------------------------------------------
-- [Helper] XML에서 특정 태그 값 추출 (단순 패턴 매칭)
-----------------------------------------------------------------------
local function extract_xml_tags(xml, tag)
  local results = {}
  for val in string.gmatch(xml, "<" .. tag .. ">(.-)%s*</" .. tag .. ">") do
    table.insert(results, val)
  end
  return results
end

-----------------------------------------------------------------------
-- [Helper] KST 오늘 날짜 반환
-- Edge 드라이버는 UTC 기반이므로 +9시간 오프셋 적용
-----------------------------------------------------------------------
function public_api.get_kst_today()
  local now_kst = os.time() + (9 * 3600)
  local t = os.date("*t", now_kst)
  return {
    year  = string.format("%04d", t.year),
    month = string.format("%02d", t.month),
    day   = string.format("%02d", t.day),
    ymd   = string.format("%04d%02d%02d", t.year, t.month, t.day),
    wday  = t.wday,  -- 1=일, 2=월, ..., 7=토
  }
end

-----------------------------------------------------------------------
-- [Core] 특일 정보 조회
--  @param device: ST 디바이스 (preferences.proxyUrl, field "api_key_public")
--  @param today:  get_effective_today() 반환 구조체 (nil이면 모듈 내부 산정)
--  @return: is_holiday(bool), holiday_name(string), err(string|nil)
-----------------------------------------------------------------------
function public_api.check_today(device, today)
  local api_key = device:get_field("api_key_public")
  if not api_key or api_key == "" then
    return false, nil, "API키 미설정"
  end

  local proxy_url = device.preferences.proxyUrl
  if not proxy_url or proxy_url == "" then
    return false, nil, "proxyUrl 미설정"
  end

  -- today 구조체가 없으면 현재 KST 산정 (fallback)
  if not today then
    local now_kst = os.time() + (9 * 3600)
    local t = os.date("*t", now_kst)
    today = {
      year  = string.format("%04d", t.year),
      month = string.format("%02d", t.month),
      ymd   = string.format("%04d%02d%02d", t.year, t.month, t.day),
    }
  else
    today = {
      year  = string.format("%04d", today.year),
      month = string.format("%02d", today.month),
      ymd   = today.ymd,
    }
  end

  local proxy_base = proxy_url:gsub("/+$", "")
  local is_hol_final = false
  local found_name = nil

  -- 1) getRestDeInfo (공휴일+국경일) 2) getAnniversaryInfo (기념일) 순차 조회
  local endpoints = { "getRestDeInfo", "getAnniversaryInfo" }
  
  for _, endpoint in ipairs(endpoints) do
    local target_url = string.format(
      "http://apis.data.go.kr/B090041/openapi/service/SpcdeInfoService/%s?serviceKey=%s&solYear=%s&solMonth=%s&numOfRows=30&_type=xml",
      endpoint, api_key, today.year, today.month
    )
    local proxy_request_url = proxy_base .. "/api/forward?url=" .. target_url

    log.info(string.format("[공공API] %s 요청 (%s년 %s월)", endpoint, today.year, today.month))

    local resp_chunks = {}
    local ok, code = pcall(function()
      local _, c, _, _ = http.request({
        url    = proxy_request_url,
        method = "GET",
        sink   = ltn12.sink.table(resp_chunks),
        headers = { ["accept"] = "application/xml" },
        timeout = 5 -- 각 요청당 타임아웃 단축
      })
      return c
    end)

    if ok and tonumber(code) == 200 then
      local xml = table.concat(resp_chunks)
      for item in string.gmatch(xml, "<item>(.-)</item>") do
        local locdate = string.match(item, "<locdate>(%d+)</locdate>")
        if locdate == today.ymd then
          local datename = string.match(item, "<dateName>([^<]+)</dateName>")
          local is_holiday_tag = string.match(item, "<isHoliday>([^<]+)</isHoliday>")
          
          found_name = datename or found_name
          if is_holiday_tag == "Y" then
            is_hol_final = true
          end
        end
      end
    end
  end

  if found_name then
    log.info(string.format("[공공API] 오늘(%s) 정보 발견: %s (휴일여부: %s)", today.ymd, found_name, tostring(is_hol_final)))
    return is_hol_final, found_name, nil
  else
    log.info("[공공API] 오늘(" .. today.ymd .. ") 정보 없음")
    return false, nil, nil
  end
end

return public_api
