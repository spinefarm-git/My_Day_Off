-----------------------------------------------------------------------
-- discovery.lua
--  - SmartThings 앱에서 "주변 기기 검색" 시 호출
--  - 가상 디바이스 1개를 고정 DNI로 생성 (중복 방지)
-----------------------------------------------------------------------

local log = require "log"
local discovery = {}

function discovery.handle_discovery(driver, _should_continue)
  log.info("mydayoff-spinefarm: 장치 찾기 시작")

  local metadata = {
    type = "LAN",
    device_network_id = "mydayoff-spinefarm-01",   -- 고정 ID (중복 생성 방지)
    label = "My Day Off Spinefarm",
    profile = "my-day-off-main",                    -- profiles/*.yaml의 name과 일치
    manufacturer = "SmartThings",
    model = "v1",
    vendor_provided_label = "Virtual"
  }

  driver:try_create_device(metadata)

  -- 만약 기존 디바이스(-01)에서 '동일 디바이스 추가' 설정이 켜져 있다면 -02도 생성 시도
  for _, device in ipairs(driver:get_devices()) do
    if device.device_network_id == "mydayoff-spinefarm-01" then
      if device.preferences and device.preferences.addSameDevice then
        log.info("mydayoff-spinefarm: 설정에 따라 Child Device 생성 시도")
        driver:try_create_device({
          type = "LAN",
          device_network_id = "mydayoff-spinefarm-02",
          label = "My Day Off Spinefarm (Copy 1)",
          profile = "my-day-off-main",
          manufacturer = "SmartThings",
          model = "v1",
          vendor_provided_label = "Virtual"
        })
      end
      break
    end
  end
end

return discovery
