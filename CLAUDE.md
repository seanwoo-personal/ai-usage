# AI Usage — 작업 안내

macOS 메뉴 막대 앱(SwiftPM, Xcode 없이 Command Line Tools로 빌드). 소스는 `Sources/AIUsage/`.
사용자와는 한국어로 대화한다.

## 새 버전 배포 절차

"새 버전 내줘" / "배포해줘" 요청이 오면 아래 순서를 그대로 따른다.

1. **버전 정하기**: 마지막 릴리스는 `gh release list --repo seanwoo-personal/ai-usage --limit 1`로 확인한다.
   기능 추가는 minor(1.1.0 → 1.2.0), 버그 수정만 있으면 patch(1.1.0 → 1.1.1). 애매하면 사용자에게 묻는다.
2. **테스트**: `./scripts/selftest.sh` → `ALL PASSED`가 아니면 멈추고 고친다.
3. **빌드**: `rm -rf .build && VERSION=<버전> ./scripts/build-app.sh`
   - 결과: `dist/AI Usage.app`, `dist/AI-Usage-<버전>.dmg`, `dist/AI-Usage-<버전>.zip`, `dist/AI-Usage.zip`
   - `.build`를 지우는 이유: 폴더를 옮기거나 경로가 바뀌면 이전 모듈 캐시 때문에 빌드가 깨진다.
4. **로컬 설치 확인**: `AIUSAGE_ZIP_URL="file://$PWD/dist/AI-Usage.zip" bash scripts/install.sh`
   → 앱이 열리고 메뉴 막대에 값이 나오는지 확인.
5. **커밋·푸시**: 커밋 메시지는 한국어, 끝에 `Co-Authored-By` 줄. 이 저장소의 git 이메일은
   `211646405+seanwoo-personal@users.noreply.github.com`(회사 메일이 공개 기록에 남지 않게). 바꾸지 않는다.
6. **GitHub 릴리스**: 반드시 `dist/AI-Usage.zip`(버전 없는 이름)을 포함한다 — 설치 스크립트가
   `releases/latest/download/AI-Usage.zip`을 받기 때문. DMG도 함께 올린다.
   ```bash
   gh release create v<버전> dist/AI-Usage.zip dist/AI-Usage-<버전>.dmg \
     --repo seanwoo-personal/ai-usage --title "AI Usage <버전>" --notes "<한국어 변경 사항>"
   ```
7. **실제 설치 확인**: GitHub에서 받는 한 줄 설치를 실행해 새 버전이 설치되는지 확인.
   ```bash
   curl -fsSL https://raw.githubusercontent.com/seanwoo-personal/ai-usage/main/scripts/install.sh | bash
   /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "/Applications/AI Usage.app/Contents/Info.plist"
   ```
8. 개인 환경에서 추가로 할 일이 있으면 `CLAUDE.local.md`를 따른다.

## 알아둘 점

- 이 맥의 셸에는 `log`라는 다른 명령이 있다. 시스템 로그는 반드시 `/usr/bin/log show ...`로 읽는다.
- 앱의 `NSLog` 진단 메시지는 시스템 로그에 잘 남지 않는다. 확인하려면 앱 번들 복사본의 실행 파일을
  터미널에서 직접 실행해 표준 에러를 본다. `AIUSAGE_DEBUG_LOGIN=claude|codex`를 주면 시작하자마자 해당 로그인 창이 열린다.
- 새 사용자 첫 실행 흉내: `open -n "/Applications/AI Usage.app" --args -onboarded NO -connectedClaude NO -connectedCodex NO -connection.claude none -connection.codex none`
  (실행 인자라 저장된 설정은 바뀌지 않는다. 테스트 후 인자 없이 다시 실행해 둔다.)
- 서명 인증서가 없어 임시(ad-hoc) 서명이다. 배포는 한 줄 설치가 기본이고, DMG는 "그래도 열기" 절차가 필요하다.
- 웹 로그인 팝업(Google 등)은 별도 창으로 열어야 한다. 로그인 창을 팝업 주소로 이동시키면 흰 화면에서 멈춘다.
