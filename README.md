# AI Usage

Claude와 Codex의 사용 한도(5시간 세션 · 주간 7일)를 macOS 메뉴 막대에 보여주는 앱. 만든 사람: Sean.

```
[Claude 로고] 5d 21h     [Codex 로고] 6d 1h
              76%                     75%
```

- 윗줄: 리셋까지 남은 시간 · 아랫줄: 남은 퍼센트
- 클릭하면 한도별 상세(진행 막대, 리셋 시각, 균등 사용 기준선)와 설정이 열립니다.
- 서비스마다 메뉴 막대에 표시할 한도(주간 / 5시간 / 둘 다)를 고를 수 있습니다. 실제로 있는 한도만 선택지로 나옵니다.

## 설치

터미널에 한 줄 (경고 창 없이 설치되고 안내 창이 열립니다):

```bash
curl -fsSL https://raw.githubusercontent.com/seanwoo-personal/ai-usage/main/scripts/install.sh | bash
```

또는 DMG(`dist/AI-Usage-<버전>.dmg`) — 서명되지 않은 앱이라 처음 한 번 "그래도 열기"가 필요합니다. DMG 안의 `처음 실행하는 방법.txt` 참고.

요구 사항: macOS 13 이상 (로고는 14 이상, 13에서는 글자로 표시). Claude는 Pro·Max, Codex는 ChatGPT 유료 요금제 계정.

## 연결 방식

| | 웹 로그인 (기본) | 터미널 CLI 로그인 (선택) |
|---|---|---|
| Claude | 앱 안 로그인 창에서 claude.ai 로그인 → `claude.ai/api/organizations/{org}/usage` | Claude Code 키체인 토큰 → `api.anthropic.com/api/oauth/usage` |
| Codex | 앱 안 로그인 창에서 chatgpt.com 로그인 → `chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` → 같은 API, 실패 시 `~/.codex/sessions` 로그 |

- 웹 로그인 세션은 앱 전용 WebKit 저장소에 보관되고, 사용량 조회는 로그인된 페이지 안에서 실행됩니다. 앱 코드는 쿠키·토큰을 직접 다루지 않습니다.
- CLI 로그인은 읽기만 하고 갱신·저장하지 않습니다.
- 조회 시점: 앱 실행, 3분마다(설정 1·3·5·10·15분), 팝업 열 때(1분 경과 시), 잠자기 해제 후, ↻(⌘R). 네트워크 오류는 1분 뒤, 요청 제한은 5분 뒤 자동 재시도.
- 모든 오류는 카드에 이유와 해결 버튼(다시 로그인 / 웹으로 로그인 / 터미널에서 갱신 / 다시 시도)으로 표시되고, 마지막으로 받은 값은 계속 보여줍니다.
- 처음 실행하면 3단계 안내 창(소개 → 연결 → 완료)이 열립니다. 팝업의 "사용 안내"로 다시 열 수 있습니다.

## 빌드

Xcode 없이 Command Line Tools만으로 빌드됩니다.

```bash
./scripts/selftest.sh     # 파싱·표시 로직 자체 테스트
./scripts/build-app.sh    # dist/AI Usage.app, AI-Usage-<버전>.dmg, .zip, AI-Usage.zip(릴리스용)
```

환경 변수:

- `VERSION` — 앱 버전 (기본 1.0.0)
- `BUNDLE_ID` — 기본 `com.sean.aiusage`
- `SIGN_IDENTITY` — `"Developer ID Application: 이름 (TEAMID)"`, 없으면 임시(ad-hoc) 서명
- `NOTARY_PROFILE` — `xcrun notarytool store-credentials`로 만든 프로필 이름, 있으면 공증까지 진행

## 배포 시 참고

임시 서명 빌드를 받은 사람은 처음 실행할 때 **시스템 설정 > 개인정보 보호 및 보안 > 그래도 열기**를 눌러야 합니다. 이 과정 없이 배포하려면 Apple Developer Program의 Developer ID로 서명하고 공증하세요.

로고 경로는 Simple Icons(CC0)에서 가져왔습니다. Claude, Anthropic, OpenAI, Codex는 각 회사의 상표입니다.
