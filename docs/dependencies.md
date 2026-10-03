# 연결된 상태 표시 경로

2026-10-04 Sean의 MCP 수정 배포 요청으로 확인했습니다. 이번 작업 담당은 Codex입니다.

M1·M5 AI Usage → 상태 파일 → 로컬 stdio MCP → tablet_dashboard 전송 프로그램 → M5 상태 API → 태블릿 GQ 현황판.

| 연결 | 형식·호환 | 갱신 주기 | 실행 위치·근거 |
| --- | --- | --- | --- |
| 측정 → 상태 파일 | AI Usage status schema_version 1, 원자적 저장, 기존 형식 유지 | 1.7.3부터 측정·저장 각각 0.5초, MCP 공유 시 메뉴 막대 표시 여부와 무관 | M1·M5 /Applications/AI Usage.app, main.swift와 SystemMonitor.swift |
| 상태 파일 → MCP | get_status, include_history=false, 요청마다 저장값 응답 | MCP는 자체 푸시하지 않음, 호출자 주기로 응답 | AIUsage mcp, docs/mcp.md |
| MCP → API | 기존 인증과 POST /status/macs/M1 또는 M5 유지 | 목표 0.5초, 요청 시간 차감; 오류 시 5초 후 재연결 | 각 Mac ~/tablet_dashboard/tools/mcp_status_push.py, com.goqual.gqvoice.status-push |
| API → 태블릿 | 기존 GET /status/macs, Mac app_version·generated_at·수치 전달 | 서버는 POST마다 갱신, 앱 조회 500ms, 조회 오류 시 5초 후 재시도 | M5 회의실 서버 8765, tablet_dashboard BoardActivity.kt |

실제 네트워크·요청 처리 지연 때문에 소비 화면 도착 간격이 정확히 0.5초라는 보장은 없습니다. JSON 시각 문자열은 초 단위이며, 반초 갱신 검증에는 파일 수정 시각과 실제 수치 변화를 함께 사용합니다.

외부 Claude·Codex 사용량 조회와 인터넷 연결 검사는 별도 주기를 유지합니다. 빠르게 갱신하는 대상은 로컬 시스템 수치와 MCP 공유 데이터입니다. 관련 원본은 [MCP 안내](mcp.md)와 tablet_dashboard/docs/structure.md입니다.

배포 순서: 앱 검사와 universal 빌드 → 로컬 설치 → 릴리스 → M1·M5 설치 → 지속 MCP 전송 서비스 재시작 → 파일·MCP·API·태블릿 확인. 승인 근거와 실제 결과는 reports/handoff_mcp_half_second_20261004.md에 보존합니다. 관제실 등록 반영은 관제실 담당의 별도 확인이 필요합니다.
