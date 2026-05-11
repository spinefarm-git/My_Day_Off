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
-- [Core] 월 단위 특일 데이터 조회 (다운로드만, 날짜 필터 없음)
--  @return items = [{locdate, name, is_holiday}], err
-----------------------------------------------------------------------
function public_api.fetch_month(device, year, month)
  local api_key = device:get_field("api_key_public")
  if not api_key or api_key == "" then
    return nil, "API키 미설정"
  end

  local proxy_url = device.preferences.proxyUrl
  if not proxy_url or proxy_url == "" then
    return nil, "proxyUrl 미설정"
  end

  local year_str  = string.format("%04d", year)
  local month_str = string.format("%02d", month)
  local proxy_base = proxy_url:gsub("/+$", "")

  -- getRestDeInfo : 법정 공휴일·국경일 (isHoliday=Y 판정 기준)
  -- getAnniversaryInfo : 기념일 (현충일·삼일절 등, 대부분 isHoliday=N이지만 dateName 표시용으로 포함)
  -- → 두 엔드포인트는 같은 구조(isHoliday 필드)를 반환하며, 공휴일 판정은 getRestDeInfo로 충분하나
  --   기념일 이름도 UI에 노출하기 위해 getAnniversaryInfo도 함께 조회함
  local endpoints = { "getRestDeInfo", "getAnniversaryInfo" }

  local items = {}
  for _, endpoint in ipairs(endpoints) do
    local target_url = string.format(
      "http://apis.data.go.kr/B090041/openapi/service/SpcdeInfoService/%s?serviceKey=%s&solYear=%s&solMonth=%s&numOfRows=30&_type=xml",
      endpoint, api_key, year_str, month_str
    )
    local proxy_request_url = proxy_base .. "/api/forward?url=" .. target_url

    log.info(string.format("[공공API] %s 요청 (%s년 %s월)", endpoint, year_str, month_str))

    local resp_chunks = {}
    local ok, code = pcall(function()
      local _, c = http.request({
        url     = proxy_request_url,
        method  = "GET",
        sink    = ltn12.sink.table(resp_chunks),
        headers = { ["accept"] = "application/xml" },
        timeout = 5
      })
      return c
    end)

    if ok and tonumber(code) == 200 then
      local xml = table.concat(resp_chunks)
      for item_xml in string.gmatch(xml, "<item>(.-)</item>") do
        local locdate    = string.match(item_xml, "<locdate>(%d+)</locdate>")
        local datename   = string.match(item_xml, "<dateName>([^<]+)</dateName>")
        local is_hol_tag = string.match(item_xml, "<isHoliday>([^<]+)</isHoliday>")
        if locdate then
          table.insert(items, {
            locdate    = locdate,
            name       = datename,
            is_holiday = (is_hol_tag == "Y"),
          })
        end
      end
    else
      log.warn(string.format("[공공API] %s 요청 실패 (HTTP %s)", endpoint, tostring(code)))
      return nil, string.format("%s 요청 실패", endpoint)
    end
  end

  return items, nil
end

-----------------------------------------------------------------------
-- [Core] 이미 조회된 월 데이터에서 특정 날짜 판정
--  @return is_holiday(bool), holiday_name(string|nil), err(nil)
-----------------------------------------------------------------------
function public_api.check_date_from_items(items, ymd)
  local is_hol_final = false
  local found_name   = nil
  for _, item in ipairs(items) do
    if item.locdate == ymd then
      found_name = item.name or found_name
      if item.is_holiday then is_hol_final = true end
    end
  end
  if found_name then
    log.info(string.format("[공공API] %s 정보 발견: %s (휴일여부: %s)", ymd, found_name, tostring(is_hol_final)))
    return is_hol_final, found_name, nil
  else
    log.info("[공공API] " .. ymd .. " 정보 없음")
    return false, nil, nil
  end
end

-----------------------------------------------------------------------
-- [Convenience] 월 조회 + 날짜 판정 한 번에 (기존 호환)
-----------------------------------------------------------------------
function public_api.check_today(device, today)
  local year, month, ymd
  if today then
    year  = today.year
    month = today.month
    ymd   = today.ymd
  else
    local now_kst = os.time() + (9 * 3600)
    local t = os.date("*t", now_kst)
    year  = t.year
    month = t.month
    ymd   = string.format("%04d%02d%02d", t.year, t.month, t.day)
  end

  local items, err = public_api.fetch_month(device, year, month)
  if err then return false, nil, err end
  return public_api.check_date_from_items(items, ymd)
end

return public_api
