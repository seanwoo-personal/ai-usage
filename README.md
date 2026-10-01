# AI Usage

Claude와 Codex를 **얼마나 더 쓸 수 있는지**, 그리고 **언제 다시 채워지는지** Mac 메뉴 막대에서 바로 보여 주는 앱입니다.

![메뉴 막대에 표시된 AI Usage (밝은/어두운 메뉴 막대)](docs/images/menubar.png)

- 윗줄: 한도가 다시 채워지기까지 남은 시간 (`5d 18h` = 5일 18시간)
- 아랫줄: 남은 사용량
- 클릭하면 5시간·주간 한도별 자세한 정보와 설정이 열립니다.

---

## 설치 (1분)

**1. 터미널을 엽니다.**
키보드에서 `⌘ Command` + `Space`를 누르고 `터미널`(또는 `Terminal`)을 입력한 뒤 `Enter`를 누릅니다.

**2. 아래 명령을 복사해서 터미널에 붙여넣고 `Enter`를 누릅니다.**
상자 오른쪽 위의 복사 버튼을 누르면 한 번에 복사됩니다.

```bash
curl -fsSL https://raw.githubusercontent.com/seanwoo-personal/ai-usage/main/scripts/install.sh | bash
```

**3. 자동으로 열리는 안내 창에서 Claude와 ChatGPT 계정을 연결합니다.**
평소 쓰는 계정으로 한 번만 로그인하면 끝입니다. 터미널에서 Claude Code나 Codex를 쓰고 있다면 버튼 하나로 바로 연결할 수도 있습니다.

> 이 방법은 Mac 암호를 묻지 않고 "확인되지 않은 개발자" 경고 창도 뜨지 않습니다.
> 대신 Apple의 검사(공증)를 거치지 않은 앱을 설치한다는 뜻이기도 합니다. 설치 스크립트가 릴리스의 해시(파일 지문)와
> 앱 서명의 무결성을 확인하고, 문제가 있으면 기존 앱을 그대로 둔 채 멈추지만, 만든 사람을 Apple이 보증하지는 않습니다.

<details>
<summary>터미널 대신 DMG 파일로 설치하기</summary>

1. [최신 릴리스](https://github.com/seanwoo-personal/ai-usage/releases/latest)에서 `AI-Usage-<버전>.dmg`를 내려받아 엽니다.
2. `AI Usage`를 옆의 `Applications` 폴더로 끌어다 놓습니다. (DMG 창에서 바로 실행하지 말고 꼭 옮겨 주세요.)
3. 응용 프로그램 폴더에서 AI Usage를 열면 경고 창이 뜹니다. **반드시 [완료]를 누르세요.** [휴지통으로 이동]을 누르면 앱이 지워집니다.
4. **시스템 설정 → 개인정보 보호 및 보안**을 열고 맨 아래의 **[그래도 열기]**를 누른 뒤 Mac 암호를 입력합니다.
5. 다시 열면 됩니다. 이후로는 평소처럼 열립니다.

Apple 유료 개발자 인증을 받지 않은 앱이라 생기는 과정입니다. 터미널 설치를 쓰면 이 과정이 없습니다.

</details>

**필요한 것:** macOS 13(Ventura) 이상, Claude Pro·Max 구독 또는 ChatGPT 유료 요금제(Codex 한도)

---

## 업데이트

앱이 하루에 한 번 새 버전을 확인합니다. 새 버전이 있으면 메뉴 막대 아이콘을 눌렀을 때 맨 위에 **"새 버전이 나왔어요 [업데이트]"**가 보이고, 누르면 확인을 거쳐 설치한 뒤 앱이 다시 열립니다. 설정에서 자동 확인을 끄거나 "지금 확인"을 누를 수 있습니다.

터미널에서 설치할 때와 같은 명령을 다시 실행해도 최신 버전으로 바뀝니다. 연결한 계정과 설정은 그대로 유지됩니다.

```bash
curl -fsSL https://raw.githubusercontent.com/seanwoo-personal/ai-usage/main/scripts/install.sh | bash
```

## 삭제

1. 메뉴 막대의 AI Usage를 누르고 **설정 → "Mac에 로그인하면 자동으로 실행"을 끕니다.** (켜 둔 채 지우면 로그인 항목에 빈 항목이 남습니다.)
2. 아래 명령으로 앱을 종료하고 지웁니다.

```bash
osascript -e 'quit app "AI Usage"'; rm -rf "/Applications/AI Usage.app"
```

연결한 계정과 설정까지 모두 지우려면 이어서 아래 명령도 실행합니다.

```bash
rm -rf ~/Library/Preferences/com.sean.aiusage.plist ~/Library/Caches/com.sean.aiusage ~/Library/HTTPStorages/com.sean.aiusage ~/Library/HTTPStorages/com.sean.aiusage.binarycookies ~/Library/WebKit/com.sean.aiusage
```

---

## 안전한가요?

- **가져오는 건 남은 사용량(%)과 리셋 시간뿐입니다.** 대화 내용, 파일, 결제 정보는 저장하거나 보내지 않습니다.
- **로그인 정보는 개발자에게 보내지 않습니다.** 이 앱에는 개발자 서버가 없습니다. 로그인 정보는 Anthropic(claude.ai, api.anthropic.com)과 OpenAI(chatgpt.com) 공식 서버에 로그인하고 사용량을 물어볼 때만 쓰입니다.
- **비밀번호는 공식 로그인 페이지에 직접 입력됩니다.** 앱은 비밀번호를 읽거나 저장하지 않습니다. 로그인 창은 지금 보고 있는 주소가 공식 사이트인지, Google·Apple 같은 로그인 단계인지, 그 밖의 사이트인지 구분해서 알려 줍니다.
- **터미널 로그인(Claude Code·Codex)을 쓸 때:** 각 도구가 저장해 둔 로그인 정보를 읽기만 하고 고치거나 지우지 않습니다. Codex는 서버 조회가 안 될 때 대화 기록 파일(`~/.codex/sessions`)의 끝부분을 읽어 사용량 숫자만 꺼내고, 대화 내용은 저장하거나 보내지 않습니다.
- **연결 해제:** 앱 안에 저장된 그 서비스의 로그인이 지워집니다. Google·Apple 로그인 상태는 두 서비스가 함께 쓰므로, 웹으로 연결된 서비스를 모두 해제할 때 함께 지워집니다. Claude Code·Codex 자체의 로그인은 그대로 둡니다.
- **업데이트 확인:** 하루 한 번 GitHub(api.github.com)에 최신 버전을 묻습니다. 설정에서 끌 수 있습니다.
- 소스 코드가 모두 공개되어 있습니다(이 저장소).

## 자주 묻는 질문

<details>
<summary>로그인 창에서 Google 로그인이 막혀요</summary>

Google이 앱 안 로그인 창을 막는 경우가 있습니다. 같은 로그인 화면에서 **이메일로 로그인**(또는 Apple로 로그인)을 이용해 주세요.

</details>

<details>
<summary>숫자가 안 바뀌거나 "!"가 보여요</summary>

메뉴 막대 아이콘을 누르면 이유와 해결 버튼(다시 로그인 / 다시 시도 등)이 카드에 표시됩니다. 오른쪽 위 ↻ 버튼(⌘R)으로 바로 새로고침할 수도 있습니다.

</details>

<details>
<summary>얼마나 자주 새로 받아오나요?</summary>

3분마다(설정에서 1~15분), 메뉴를 열 때, Mac이 잠자기에서 깨어날 때 받아옵니다. 리셋까지 남은 시간은 서버에 묻지 않고 계속 줄어듭니다.

</details>

<details>
<summary>"Mac에 로그인하면 자동으로 실행"이 안 켜져요</summary>

앱이 응용 프로그램 폴더에 있을 때만 켤 수 있습니다. DMG 창이나 다운로드 폴더에서 바로 실행 중이라면, 응용 프로그램 폴더로 옮긴 뒤 다시 켜 주세요.

</details>

---

## 개발자용

<details>
<summary>동작 방식</summary>

| | 웹 로그인 (기본) | 터미널 CLI 로그인 (선택) |
|---|---|---|
| Claude | 앱 안 로그인 창에서 claude.ai 로그인 → `claude.ai/api/organizations/{org}/usage` | Claude Code 키체인 토큰 → `api.anthropic.com/api/oauth/usage` |
| Codex | 앱 안 로그인 창에서 chatgpt.com 로그인 → `chatgpt.com/backend-api/wham/usage` | `~/.codex/auth.json` → 같은 API, 실패 시 `~/.codex/sessions` 로그 |

- 웹 로그인 세션은 앱 전용 WebKit 저장소에 보관되고, 사용량 조회는 로그인된 페이지 안에서 실행됩니다. 앱 코드는 쿠키·토큰을 직접 다루지 않습니다.
- CLI 로그인은 읽기만 하고 갱신·저장하지 않습니다.
- 네트워크 오류는 1분 뒤, 요청 제한은 5분 뒤 자동 재시도합니다.
- 위 주소들은 공개 API가 아니라 각 사이트가 자기 화면에서 쓰는 주소라, 사이트가 바뀌면 동작이 멈출 수 있습니다.

</details>

<details>
<summary>빌드</summary>

Xcode 없이 Command Line Tools만으로 빌드됩니다.

```bash
./scripts/selftest.sh     # 앱 로직 테스트 + 설치 스크립트 격리 테스트(scripts/test-install.sh)
VERSION=1.2.0 ./scripts/build-app.sh    # dist/AI Usage.app, AI-Usage-<버전>.dmg, .zip, AI-Usage.zip(릴리스용)
```

- `VERSION`: 앱 버전 (기본 1.0.0)
- 번들 ID는 `com.sean.aiusage`로 고정돼 있어 바꿀 수 없습니다(설정·로그인 정보·로그인 항목이 이 ID에 묶여 있음).
- `SIGN_IDENTITY`: `"Developer ID Application: 이름 (TEAMID)"`, 없으면 임시(ad-hoc) 서명 + 강화된 런타임
- `NOTARY_PROFILE`: `xcrun notarytool store-credentials`로 만든 프로필 이름, 있으면 공증까지 진행(아직 실제로 검증하지 않음)
- 빌드 결과에 `AI-Usage.zip.sha256`이 함께 만들어집니다. 릴리스에 꼭 같이 올려야 설치·업데이트가 동작합니다.

설치 스크립트(`scripts/install.sh`)는 정확한 릴리스 버전을 고정하고, HTTPS로만 받고, 해시·압축 경로·번들 ID·실행 파일·아키텍처·최소 macOS·서명 무결성을 확인한 다음, 설치 위치 옆에 복사해 두고 마지막에 바꿔치기합니다. 실패하면 기존 앱으로 되돌립니다. 앱 안의 업데이트 기능도 같은 스크립트를 씁니다. 해시는 앱과 같은 릴리스에서 받으므로, 릴리스 자체가 바뀐 경우까지 막지는 못합니다.

로고 경로는 Simple Icons(CC0)에서 가져왔습니다. Claude, Anthropic, OpenAI, Codex는 각 회사의 상표입니다.

</details>

## 라이선스

[MIT](LICENSE) © 2026 Sean Woo
