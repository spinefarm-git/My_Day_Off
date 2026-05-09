# My Day Off

오늘이 휴일인지 4가지 기준으로 자동 판정하는 SmartThings Edge 드라이버입니다.

## 휴일 판정 기준

| # | 기준 | 설명 |
|---|------|------|
| ① | 공공API | 한국천문연구원 특일정보 (data.go.kr) |
| ② | 등록된 캘린더 | 등록된 캘린더의 오늘 일정(키워드 포함) 여부 |
| ③ | 특정 날짜 지정 | 개교기념일, 창립기념일 등 (웹서버에서 설정) |
| ④ | 고정 요일 규칙 | 기본값: 토·일요일 (웹서버에서 변경 가능) |

4가지 중 **하나라도 해당하면 휴일** 판정 → switch **OFF**

## ST 앱 화면 구성

- **main 컴포넌트**: switch (ON=평일 / OFF=휴일)
- **holidayDetails 컴포넌트**: 4가지 판정 결과 상세 표시

## 커스텀 Capability 등록 필요

`achievedictionary39087.holidayJudgement` capability를 ST Developer Console에서 등록해야 합니다.

`capability/holidayJudgement/capability.yaml` 파일을 참조하세요.

## 설정 방법

1. ST 드라이버 설치 후 **Edge Bridge URL** preferences 입력
2. preferences의 **"설정 웹서버 실행"** 토글 ON
3. 드라이버 로그에서 웹서버 URL 확인 (예: `http://192.168.0.xxx:XXXXX`)
4. 브라우저로 접속 → 4가지 설정 입력 및 저장

## 웹서버 설정 항목

### ① 공공API 키 (한국천문연구원 특일정보)
- data.go.kr → 마이페이지 → 인증키 → **일반 인증키(Decoding)** 복사

### ② 등록된 캘린더 iCal URL 및 키워드
- Google Calendar → 캘린더 설정 → **비공개 주소 > iCal** 버튼 복사
- 여러 캘린더를 등록할 수 있으며, 공통 키워드를 지정하면 해당 키워드가 포함된 일정만 휴일로 판정합니다.

### ③ 특정 날짜 지정
- 형식: `MM/DD=비고` (쉼표 구분)
- 예: `03/01=삼일절, 10/03=개교기념일, 12/25=성탄절`

### ④ 고정 요일 설정
- 체크박스로 요일 선택 (기본값: 토·일)

## 갱신 주기

- **자동**: 매일 00:01 KST
- **수동**: ST 앱에서 Refresh 버튼

## Edge Bridge 요구 사항

외부 HTTP/HTTPS 요청에 `/proxy?url=<encoded>` 엔드포인트를 지원해야 합니다.

## 파일 구조

```
My_Day_Off/
├── config.yaml
├── profiles/
│   └── my-day-off-main.yaml
├── capability/
│   └── holidayJudgement/
│       └── capability.yaml
└── src/
    ├── init.lua              # 드라이버 엔트리, 라이프사이클
    ├── discovery.lua         # 가상 디바이스 생성
    ├── holiday_checker.lua   # 4가지 판정 통합
    ├── public_api.lua        # 한국천문연구원 공공API
    ├── ical_parser.lua       # Google Calendar iCal 파싱
    ├── common_web_server.lua # HTTP 서버
    └── html.lua              # 설정 웹 UI
```
