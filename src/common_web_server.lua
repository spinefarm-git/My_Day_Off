-- common_web_server.lua
-- Generic HTTP Server for Edge Driver (weather-api-spinefarm 기반)
local cosock = require "cosock"
local socket = require "cosock.socket"
local log = require "log"

local common_server = {}

-- [Config]
local MAX_BODY_SIZE = 4096  -- 설정값(날짜목록 등)이 길 수 있으므로 넉넉히
local RATE_LIMIT_WINDOW = 1 -- second
local MAX_REQS_PER_WINDOW = 5

-- [State]
local cached_ip = nil
local rate_limit_counts = 0
local last_rate_check = 0

-- [Helper] IP Caching
function common_server.get_local_ip()
  if cached_ip then return cached_ip end

  local s = socket.udp()
  s:setpeername("8.8.8.8", 80)
  local ip, _ = s:getsockname()
  s:close()

  cached_ip = ip
  return ip
end

-- [Helper] URL Decode
function common_server.url_decode(s)
  if not s then return "" end
  s = string.gsub(s, "+", " ")
  s = string.gsub(s, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
  return s
end

-- [Helper] Rate Limiter
local function check_rate_limit()
  local now = os.time()
  if now > last_rate_check + RATE_LIMIT_WINDOW then
    rate_limit_counts = 0
    last_rate_check = now
  end

  rate_limit_counts = rate_limit_counts + 1
  if rate_limit_counts > MAX_REQS_PER_WINDOW then
    return false -- Block
  end
  return true -- Pass
end

-- [Internal] Handle Client
local function handle_client(client, request_processor)
  client:settimeout(5)

  -- 1. Read Request Line
  local request_line, err = client:receive()
  if not request_line then client:close() return end

  local method, path, _ = string.match(request_line, "^(%u+)%s+(.-)%s+HTTP/%d%.%d$")
  if not method then client:close() return end

  -- 2. Read Headers
  local content_length = 0
  local headers = {}

  while true do
    local line, _ = client:receive()
    if not line or line == "" then break end
    local key, val = string.match(line, "^(.-):%s*(.*)$")
    if key then
      key = string.lower(key)
      headers[key] = val
      if key == "content-length" then
        content_length = tonumber(val) or 0
      end
    end
  end

  -- 3. Read Body
  local body = nil
  if content_length > 0 then
    if content_length > MAX_BODY_SIZE then
      log.warn("WEB_SERVER: Payload too large (" .. content_length .. "B)")
      client:send("HTTP/1.1 413 Payload Too Large\r\n\r\nMax 4096B")
      client:close()
      return
    end
    body, _ = client:receive(content_length)
  end

  -- 4. Process Request
  local status_code, content_type, response_body = request_processor(method, path, headers, body)

  if not response_body then
    response_body = "Internal Server Error"
    status_code = 500
    content_type = "text/plain"
  end

  -- Default values
  status_code = status_code or 200
  content_type = content_type or "text/html; charset=utf-8"

  local response = string.format(
    "HTTP/1.1 %d OK\r\n" ..
    "Content-Type: %s\r\n" ..
    "Content-Length: %d\r\n" ..
    "Connection: close\r\n" ..
    "\r\n" ..
    "%s",
    status_code,
    content_type,
    #response_body,
    response_body
  )

  client:send(response)
  client:close()
end

-- [Core] Start Server
function common_server.start(port, request_processor)
  local target_port = port or 0

  -- Create TCP socket
  local s = socket.tcp()
  if not s then
    log.error("WEB_SERVER: Failed to create socket")
    return nil, nil, nil
  end

  -- Bind
  local res, err = s:bind("*", target_port)
  if not res then
    log.error("WEB_SERVER: Failed to bind: " .. tostring(err))
    return nil, nil, nil
  end

  local _, assigned_port = s:getsockname()
  local ip = common_server.get_local_ip()

  res, err = s:listen()
  if not res then
    log.error("WEB_SERVER: Failed to listen: " .. tostring(err))
    return nil, nil, nil
  end

  log.info("WEB_SERVER: Listening on " .. tostring(ip) .. ":" .. tostring(assigned_port))

  -- Main Loop
  cosock.spawn(function()
    while true do
      local client, accept_err = s:accept()
      if client then
        if check_rate_limit() then
          cosock.spawn(function()
            handle_client(client, request_processor)
          end, "web_server_client")
        else
          log.warn("WEB_SERVER: Rate limit exceeded, dropping connection")
          client:close()
        end
      else
        log.error("WEB_SERVER: Accept error: " .. tostring(accept_err))
        socket.sleep(1)
      end
    end
  end, "web_server_main")

  return ip, assigned_port, s
end

return common_server
