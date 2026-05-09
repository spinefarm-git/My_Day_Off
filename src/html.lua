-----------------------------------------------------------------------
-- html.lua
--  - mydayoff-spinefarm 설정 웹 UI
--  - 4가지 설정 항목을 하나의 페이지에서 처리
--  - KST 시각 표기
-----------------------------------------------------------------------

local html = {}

-- [Helper] HTML Escape (XSS 방지)
function html.escape(s)
  if not s then return "" end
  s = string.gsub(s, "&", "&amp;")
  s = string.gsub(s, "<", "&lt;")
  s = string.gsub(s, ">", "&gt;")
  s = string.gsub(s, '"', "&quot;")
  s = string.gsub(s, "'", "&#039;")
  return s
end

-- [Helper] KST 현재 시각 문자열
local function kst_now_str()
  local kst = os.time() + (9 * 3600)
  local t = os.date("*t", kst)
  local wday_names = {"일", "월", "화", "수", "목", "금", "토"}
  local wname = wday_names[t.wday] or "?"
  return string.format("%04d-%02d-%02d(%s) %02d:%02d KST",
    t.year, t.month, t.day, wname, t.hour, t.min)
end

-- [Helper] 요일 체크박스 HTML 생성
local function weekday_checkboxes(saved_weekdays)
  saved_weekdays = saved_weekdays or "17"
  local days = {
    {num="2", name="월"},
    {num="3", name="화"},
    {num="4", name="수"},
    {num="5", name="목"},
    {num="6", name="금"},
    {num="7", name="토"},
    {num="1", name="일"},
  }
  local parts = {}
  for _, d in ipairs(days) do
    local checked = string.find(saved_weekdays, d.num, 1, true) and "checked" or ""
    table.insert(parts, string.format(
      [[<label class="cb-label"><input type="checkbox" name="weekday_%s" value="%s" %s><span>%s</span></label>]],
      d.num, d.num, checked, d.name
    ))
  end
  return table.concat(parts, "\n")
end

-----------------------------------------------------------------------
-- [Template] 메인 설정 페이지
-----------------------------------------------------------------------
function html.get_settings_page(data, flash)
  data = data or {}
  flash = flash or {}

  local api_key_masked = ""
  if data.api_key_public and data.api_key_public ~= "" then
    local k = data.api_key_public
    api_key_masked = string.rep("*", math.max(0, #k - 6)) .. k:sub(-6)
  end

  local custom_dates_val = html.escape(data.custom_dates or "")
  local weekday_boxes = weekday_checkboxes(data.holiday_weekdays)
  local kst_now = kst_now_str()

  local calendars_json = "[]"
  if data.calendars_data and data.calendars_data ~= "" then
    -- It is assumed to be valid JSON string
    calendars_json = data.calendars_data
  end
  local keyword_val = html.escape(data.calendar_keyword or "")
  local weekday_kw_val = html.escape(data.weekday_keyword or "")
  local detect_mode = data.holiday_detect_mode or "google"

  local flash_html = ""
  if flash.type and flash.msg then
    local cls = (flash.type == "success") and "flash-success" or "flash-error"
    local icon = (flash.type == "success") and "✅" or "❌"
    flash_html = string.format('<div class="%s">%s %s</div>', cls, icon, html.escape(flash.msg))
  end

  return [[<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>🗓 My Day Off - Spinefarm 설정</title>
  <style>
    :root {
      --bg: #0f1117;
      --card: #1a1d27;
      --border: #2a2d3e;
      --accent: #6c63ff;
      --accent2: #ff6b6b;
      --text: #e0e0e0;
      --muted: #888;
      --green: #4caf50;
      --red: #f44336;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Segoe UI', system-ui, sans-serif;
      background: var(--bg);
      color: var(--text);
      padding: 20px;
      min-height: 100vh;
    }
    .container { max-width: 600px; margin: 0 auto; }
    .header { text-align: center; padding: 24px 0 16px; }
    .header h1 { font-size: 1.6rem; color: var(--accent); margin-bottom: 4px; }
    .header .kst { font-size: 0.8rem; color: var(--muted); }
    .card { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 20px; margin-bottom: 16px; }
    .card-title { font-size: 0.75rem; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: var(--accent); margin-bottom: 14px; display: flex; align-items: center; gap: 8px; }
    .card-title .badge { background: var(--accent); color: #fff; border-radius: 50%; width: 20px; height: 20px; display: inline-flex; align-items: center; justify-content: center; font-size: 0.7rem; }
    label.field-label { display: block; font-size: 0.78rem; color: var(--muted); margin-bottom: 5px; }
    input[type="text"], textarea { width: 100%; background: #0f1117; border: 1px solid var(--border); border-radius: 8px; color: var(--text); padding: 10px 12px; font-size: 0.85rem; font-family: monospace; outline: none; transition: border-color 0.2s; margin-bottom: 8px; }
    input[type="text"]:focus, textarea:focus { border-color: var(--accent); }
    textarea { resize: vertical; min-height: 80px; }
    .hint { font-size: 0.72rem; color: var(--muted); margin-top: 5px; line-height: 1.5; }
    .current { font-size: 0.75rem; color: #666; margin-bottom: 8px; font-family: monospace; }
    .btn { display: inline-block; padding: 9px 20px; border: none; border-radius: 8px; font-size: 0.85rem; font-weight: 600; cursor: pointer; transition: opacity 0.2s, transform 0.1s; }
    .btn:active { transform: scale(0.97); }
    .btn-primary { background: var(--accent); color: #fff; }
    .btn-primary:hover { opacity: 0.85; }
    .btn-secondary { background: var(--border); color: #fff; padding: 6px 12px; font-size: 0.8rem; }
    .btn-danger { background: var(--red); color: #fff; padding: 6px 12px; font-size: 0.8rem; }
    .btn-full { width: 100%; margin-top: 12px; padding: 11px; font-size: 0.9rem; }
    .cb-group { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 4px; }
    .cb-label { display: flex; align-items: center; gap: 5px; cursor: pointer; padding: 6px 12px; border: 1px solid var(--border); border-radius: 8px; font-size: 0.85rem; transition: border-color 0.2s, background 0.2s; user-select: none; }
    .cb-label:has(input:checked) { border-color: var(--accent); background: rgba(108,99,255,0.12); }
    .cb-label input[type="checkbox"] { accent-color: var(--accent); }
    .cb-label span { font-weight: 600; }
    .flash-success { background: rgba(76,175,80,0.15); border: 1px solid var(--green); border-radius: 8px; padding: 10px 14px; color: var(--green); font-size: 0.85rem; margin-bottom: 16px; }
    .flash-error { background: rgba(244,67,54,0.15); border: 1px solid var(--red); border-radius: 8px; padding: 10px 14px; color: var(--red); font-size: 0.85rem; margin-bottom: 16px; }
    .footer { text-align: center; font-size: 0.72rem; color: var(--muted); padding: 16px 0 24px; }
    
    .cal-item { display: flex; justify-content: space-between; align-items: center; background: #0f1117; padding: 8px 12px; border-radius: 8px; border: 1px solid var(--border); margin-bottom: 8px; }
    .cal-info { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; flex: 1; margin-right: 10px; }
    .cal-name { font-weight: bold; font-size: 0.85rem; color: var(--text); }
    .cal-url { font-size: 0.7rem; color: var(--muted); }
    .cal-inputs { display: flex; gap: 8px; margin-bottom: 8px; }
    .cal-inputs input[type="text"] { margin-bottom: 0; }
    .row { display: flex; gap: 12px; }
    .col { flex: 1; }
    .radio-group { display: flex; flex-direction: column; gap: 8px; margin-bottom: 12px; }
    .radio-label { display: flex; align-items: center; gap: 10px; cursor: pointer; padding: 10px 14px; background: #0f1117; border: 1px solid var(--border); border-radius: 8px; font-size: 0.85rem; transition: all 0.2s; }
    .radio-label:hover { border-color: var(--accent); }
    .radio-label input[type="radio"] { accent-color: var(--accent); width: 16px; height: 16px; }
    .radio-label.selected { border-color: var(--accent); background: rgba(108,99,255,0.08); }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>🗓 My Day Off - Spinefarm 설정</h1>
      <div class="kst">현재 시각: ]] .. kst_now .. [[ <br><span id="countdown" style="color:var(--accent2); font-weight:bold;"></span></div>
    </div>

    ]] .. flash_html .. [[

    <!-- ① 공휴일 판정 방식 및 API 설정 -->
    <div class="card">
      <div class="card-title"><span class="badge">1</span> 공휴일 판정 설정 (공공 API / 구글)</div>
      <form action="/save/detect_mode" method="post">
        <div class="radio-group">
          <label class="radio-label ]] .. (detect_mode == "public" and "selected" or "") .. [[">
            <input type="radio" name="mode" value="public" ]] .. (detect_mode == "public" and "checked" or "") .. [[>
            <div>
              <strong>공공 API 사용</strong>
              <div class="hint">한국천문연구원 특일정보를 조회합니다. (API키 필요)</div>
            </div>
          </label>
          <label class="radio-label ]] .. (detect_mode == "google" and "selected" or "") .. [[">
            <input type="radio" name="mode" value="google" ]] .. (detect_mode == "google" and "checked" or "") .. [[>
            <div>
              <strong>구글 캘린더 공휴일 iCal 사용</strong>
              <div class="hint">대한민국 공휴일 캘린더를 구독하여 판정합니다.</div>
            </div>
          </label>
          <label class="radio-label ]] .. (detect_mode == "none" and "selected" or "") .. [[">
            <input type="radio" name="mode" value="none" ]] .. (detect_mode == "none" and "checked" or "") .. [[>
            <div>
              <strong>미사용</strong>
              <div class="hint">공공/구글 공휴일을 조회하지 않습니다. (고정 요일/수동 날짜만 사용)</div>
            </div>
          </label>
        </div>
        <button type="submit" class="btn btn-primary btn-full">판정 방식 저장</button>
      </form>

      <div style="margin-top: 24px; padding-top: 16px; border-top: 1px solid var(--border); ]] .. (detect_mode ~= "public" and "opacity:0.5;" or "") .. [[">
        <label class="field-label" style="font-weight:bold; color:var(--text);">공공 API 키 설정</label>
        ]] .. (api_key_masked ~= "" and ('<p class="current">현재: ' .. api_key_masked .. '</p>') or "") .. [[
        <form action="/save/apikey" method="post">
          <input type="text" id="apikey" name="apikey" placeholder="서비스 키를 붙여넣기 하세요" autocomplete="off" ]] .. (detect_mode ~= "public" and "disabled" or "") .. [[>
          <p class="hint">공공데이터포털 → 마이페이지 → 인증키 → <strong>일반 인증키 (Encoding)</strong></p>
          <button type="submit" class="btn btn-primary btn-full" ]] .. (detect_mode ~= "public" and "disabled" or "") .. [[>API 키 저장</button>
        </form>
      </div>
    </div>

    <!-- ② 캘린더 등록 -->
    <div class="card">
      <div class="card-title"><span class="badge">2</span> 등록된 캘린더 및 키워드</div>
      
      <div class="row">
        <div class="col">
          <label class="field-label">공통 휴일 키워드</label>
          <input type="text" id="calendar_keyword" value="]] .. keyword_val .. [[" placeholder="예: 휴가, 연차, 반차">
        </div>
        <div class="col">
          <label class="field-label">강제 평일 키워드</label>
          <input type="text" id="weekday_keyword" value="]] .. weekday_kw_val .. [[" placeholder="예: 출근, 당직">
        </div>
      </div>
      <p class="hint">휴일 키워드는 휴일로, 강제 평일 키워드는 <strong>최우선적으로 평일</strong>로 판정합니다.<br>여러 키워드는 쉼표(,)로 구분하세요.</p>
      <br>

      <label class="field-label">등록된 캘린더 목록</label>
      <div id="calendar_list"></div>
      
      <div class="cal-inputs" style="margin-top:10px;">
        <input type="text" id="new_cal_name" placeholder="캘린더 이름 (예: 내 캘린더)" style="flex:1;">
        <input type="text" id="new_cal_url" placeholder="비공개 주소 iCal" style="flex:2;">
        <button type="button" class="btn btn-secondary" onclick="addCalendar()">추가</button>
      </div>

      <button type="button" class="btn btn-primary btn-full" onclick="saveCalendars()">저장</button>
    </div>

    <!-- ③ 특정 날짜 지정 -->
    <div class="card">
      <div class="card-title"><span class="badge">3</span> 특정 날짜 휴일 지정 (매년 반복)</div>
      <form action="/save/dates" method="post">
        <label class="field-label" for="custom_dates">날짜 목록 (MM/DD=비고, 쉼표 구분)</label>
        <textarea id="custom_dates" name="custom_dates" placeholder="05/01=근로자의날, 10/03=개교기념일, 11/01=창립기념일">]] .. custom_dates_val .. [[</textarea>
        <button type="submit" class="btn btn-primary btn-full">저장</button>
      </form>
    </div>

    <!-- ④ 고정 요일 -->
    <div class="card">
      <div class="card-title"><span class="badge">4</span> 고정 휴일 요일 설정</div>
      <form action="/save/weekdays" method="post">
        <label class="field-label">휴일로 지정할 요일 (기본: 토·일)</label>
        <div class="cb-group">
          ]] .. weekday_boxes .. [[
        </div>
        <p class="hint">체크된 요일은 항상 휴일로 판정됩니다. 모든 요일을 해제하여 사용 안 함으로 설정 가능.</p>
        <button type="submit" class="btn btn-primary btn-full">저장</button>
      </form>
    </div>

    <div class="footer">
      My Day Off Spinefarm · SmartThings Edge Driver<br>
      설정 저장 후 ST 앱에서 Refresh를 실행하세요.
    </div>
  </div>

  <script>
    let expiresAt = (]] .. (data.expires_at or 0) .. [[) * 1000;
    if (expiresAt > 0) {
      setInterval(() => {
        let now = Date.now();
        let remain = Math.floor((expiresAt - now) / 1000);
        if(remain < 0) {
          document.getElementById('countdown').innerText = "웹서버 종료됨";
          return;
        }
        let min = Math.floor(remain / 60);
        let sec = remain % 60;
        document.getElementById('countdown').innerText = "서버 종료까지 " + min + "분 " + sec + "초 남음";
      }, 1000);
    }
  
    let calendars = ]] .. calendars_json .. [[;
    if (!Array.isArray(calendars)) {
      console.warn("Calendars is not an array, initializing as empty.");
      calendars = [];
    }
    
    function renderCalendars() {
      const list = document.getElementById('calendar_list');
      list.innerHTML = '';
      if(calendars.length === 0) {
        list.innerHTML = '<p class="hint">등록된 캘린더가 없습니다.</p>';
      }
      calendars.forEach((cal, index) => {
        const div = document.createElement('div');
        div.className = 'cal-item';
        // XSS defense simplified for example
        const n = cal.name.replace(/</g, "&lt;");
        const u = cal.url.replace(/</g, "&lt;");
        div.innerHTML = `
          <div class="cal-info">
            <div class="cal-name">${n}</div>
            <div class="cal-url">${u}</div>
          </div>
          <button type="button" class="btn btn-danger" onclick="removeCalendar(${index})">X</button>
        `;
        list.appendChild(div);
      });
    }

    function addCalendar() {
      const nameInput = document.getElementById('new_cal_name');
      const urlInput = document.getElementById('new_cal_url');
      const name = nameInput.value.trim();
      const url = urlInput.value.trim();

      if(!name) {
        alert("캘린더 이름을 입력해주세요.");
        nameInput.focus();
        return;
      }
      if(!url) {
        alert("iCal 주소를 입력해주세요.");
        urlInput.focus();
        return;
      }
      if(!url.startsWith('http')) {
        alert("올바른 iCal 주소(http로 시작)를 입력해주세요.");
        urlInput.focus();
        return;
      }

      calendars.push({ name: name, url: url });
      nameInput.value = '';
      urlInput.value = '';
      renderCalendars();
    }

    function removeCalendar(index) {
      calendars.splice(index, 1);
      renderCalendars();
    }

    function saveCalendars() {
      const keyword = document.getElementById('calendar_keyword').value;
      const weekday_keyword = document.getElementById('weekday_keyword').value;
      const data = {
        keyword: keyword,
        weekday_keyword: weekday_keyword,
        calendars: calendars
      };
      
      fetch('/save/calendars', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(data)
      }).then(res => {
        window.location.href = '/success';
      }).catch(err => alert("저장 실패"));
    }

    window.onload = renderCalendars;
  </script>
</body>
</html>]]
end

-----------------------------------------------------------------------
-- [Template] 저장 성공 페이지 (리디렉션 포함)
-----------------------------------------------------------------------
function html.get_success_page(msg)
  msg = html.escape(msg or "설정이 저장되었습니다.")
  return [[<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="2;url=/">
  <title>저장 완료</title>
  <style>
    body { font-family: sans-serif; background: #0f1117; color: #e0e0e0;
           display: flex; align-items: center; justify-content: center; min-height: 100vh; }
    .box { text-align: center; }
    .icon { font-size: 3rem; margin-bottom: 12px; }
    p { color: #888; font-size: 0.9rem; margin-top: 8px; }
  </style>
</head>
<body>
  <div class="box">
    <div class="icon">✅</div>
    <h2>]] .. msg .. [[</h2>
    <p>잠시 후 설정 페이지로 돌아갑니다...</p>
  </div>
</body>
</html>]]
end

return html
