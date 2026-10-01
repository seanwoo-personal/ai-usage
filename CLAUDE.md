# AI Usage — 작업 안내

macOS 메뉴 막대 앱(SwiftPM, Xcode 없이 Command Line Tools로 빌드). 소스는 `Sources/AIUsage/`.
사용자와는 한국어로 대화한다.

## 새 버전 배포 절차

"새 버전 내줘" / "배포해줘" 요청이 오면 아래 순서를 그대로 따른다.

1. **버전 정하기**: 마지막 릴리스는 `gh release list --repo seanwoo-personal/ai-usage --limit 1`로 확인한다.
   기능 추가는 minor(1.1.0 → 1.2.0), 버그 수정만 있으면 patch(1.1.0 → 1.1.1). 애매하면 사용자에게 묻는다.
2. **테스트**: `./scripts/selftest.sh` → `ALL PASSED`가 아니면 멈추고 고친다.
   **변경 기록**: `CHANGELOG.md`의 `## [Unreleased]` 내용을 `## [<버전>] - <날짜>`로 옮기고 맨 아래 비교 링크를 추가한다.
3. **빌드**: `rm -rf .build && VERSION=<버전> ./scripts/build-app.sh`
   - 결과: `dist/AI Usage.app`, `dist/AI-Usage-<버전>.dmg`, `dist/AI-Usage-<버전>.zip`, `dist/AI-Usage.zip`
   - `.build`를 지우는 이유: 폴더를 옮기거나 경로가 바뀌면 이전 모듈 캐시 때문에 빌드가 깨진다.
4. **로컬 설치 확인**: 테스트 모드로 방금 빌드한 ZIP을 실제 위치에 설치해 본다.
   `AIUSAGE_TEST_MODE=1 AIUSAGE_ZIP_URL="file://$PWD/dist/AI-Usage.zip" AIUSAGE_SHA256="$(awk '{print $1}' dist/AI-Usage.zip.sha256)" bash scripts/install.sh`
   → 앱이 열리고 메뉴 막대에 값이 나오는지 확인. (`selftest.sh`가 설치 실패 상황은 격리된 폴더에서 따로 검사한다.)
5. **커밋·푸시**: 커밋 메시지는 영어 [Conventional Commits](https://www.conventionalcommits.org/) 형식으로 짧게 쓴다.
   제목은 50자 안팎(`fix(installer): quit the app that launched the update`, 릴리스는 `chore(release): v1.2.2`),
   자세한 내용은 본문에. GitHub 파일 목록에 제목이 그대로 보이기 때문. 끝에 `Co-Authored-By` 줄. 이 저장소의 git 이메일은
   `211646405+seanwoo-personal@users.noreply.github.com`(회사 메일이 공개 기록에 남지 않게). 바꾸지 않는다.
6. **GitHub 릴리스**: 반드시 `dist/AI-Usage.zip`과 `dist/AI-Usage.zip.sha256`을 함께 올린다. 설치 스크립트와 앱의
   자동 업데이트가 `releases/download/<태그>/` 에서 이 두 파일을 받아 해시를 확인하기 때문. 앱 버전과 태그(vX.Y.Z)가
   다르면 설치가 거부된다. DMG도 함께 올린다.
   이 저장소는 **릴리스 변경 불가(immutable releases)** 가 켜져 있어서, 발행한 뒤에는 파일 교체·태그 이동이 안 된다.
   그래서 초안으로 올려 파일을 확인한 다음 발행한다. 잘못 발행했으면 고치지 말고 다음 patch 버전을 낸다.
   ```bash
   gh release create v<버전> dist/AI-Usage.zip dist/AI-Usage.zip.sha256 dist/AI-Usage-<버전>.dmg --draft \
     --repo seanwoo-personal/ai-usage --title "AI Usage <버전>" --notes "<영어 변경 사항(CHANGELOG 그대로) + 한국어 요약>"
   gh release view v<버전> --repo seanwoo-personal/ai-usage --json assets --jq '.assets[].name'   # 세 파일 확인
   gh release edit v<버전> --repo seanwoo-personal/ai-usage --draft=false
   ```
7. **실제 설치 확인**: GitHub에서 받는 한 줄 설치를 실행해 새 버전이 설치되는지 확인.
   ```bash
   curl -fsSL https://raw.githubusercontent.com/seanwoo-personal/ai-usage/main/scripts/install.sh | bash
   /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "/Applications/AI Usage.app/Contents/Info.plist"
   ```
8. 개인 환경에서 추가로 할 일이 있으면 `CLAUDE.local.md`를 따른다.

## 저장소 문서

- `README.md`(영어, 기본)와 `README.ko.md`(한국어)는 내용을 함께 맞춘다. 화면 캡처는 `docs/images/`
  (`popover.png` 영어, `popover-ko.png` 한국어, `menubar.png`, `icon.png`). 캡처는 사용자 화면에 띄우지 않고
  가짜 데이터로 화면 밖에서 렌더링해 만든다.
- 사용자에게 보이는 변경은 `CHANGELOG.md`의 `Unreleased`에 쌓는다. `SECURITY.md`, `CONTRIBUTING.md`,
  `.github/` 이슈·PR 양식이 있다.

## 알아둘 점

- 이 맥의 셸에는 `log`라는 다른 명령이 있다. 시스템 로그는 반드시 `/usr/bin/log show ...`로 읽는다.
- 앱의 `NSLog` 진단 메시지는 시스템 로그에 잘 남지 않는다. 확인하려면 앱 번들 복사본의 실행 파일을
  터미널에서 직접 실행해 표준 에러를 본다. `AIUSAGE_DEBUG_LOGIN=claude|codex`를 주면 시작하자마자 해당 로그인 창이 열린다.
- 새 사용자 첫 실행 흉내: `open -n "/Applications/AI Usage.app" --args -onboarded NO -connectedClaude NO -connectedCodex NO -connection.claude none -connection.codex none`
  (실행 인자라 저장된 설정은 바뀌지 않는다. 테스트 후 인자 없이 다시 실행해 둔다.)
- 서명 인증서가 없어 임시(ad-hoc) 서명이지만 강화된 런타임(`--options runtime`)은 켜져 있다. 빌드 후
  `codesign -dvv "dist/AI Usage.app"`의 flags에 `runtime`이 있어야 한다.
- main 브랜치는 강제 푸시·삭제가 막혀 있다(관리자 포함). 기록을 고쳐 쓰지 말고 새 커밋으로 고친다.
- 번들 ID는 `com.sean.aiusage`로 고정이다. `build-app.sh`는 다른 `BUNDLE_ID`가 주어지면 빌드를 거부한다.
- "로그인하면 자동 실행"은 `/Applications`·`~/Applications`에서 실행 중일 때만 켤 수 있다(`LoginItem.swift`).
  빌드 폴더·DMG·임시 폴더에서 켜면 그 경로가 로그인 항목에 남아 깨지기 때문. 테스트할 땐 설치본에서 켠다.
- 서명 인증서가 없어 임시(ad-hoc) 서명이다. 배포는 한 줄 설치가 기본이고, DMG는 "그래도 열기" 절차가 필요하다.
- 웹 로그인 팝업(Google 등)은 별도 창으로 열어야 한다. 로그인 창을 팝업 주소로 이동시키면 흰 화면에서 멈춘다.
- 테스트는 실제 키체인·`~/.codex`·사용자 설정을 읽지 않는다(가짜 백엔드·가짜 시계·임시 폴더·`AppSettings.forTesting()`).
  위험한 입력은 `Tests/regression.swift`의 probe로 별도 프로세스에서 돌린다. 테스트를 추가할 때도 이 원칙을 지킨다.
- 앱의 자동 업데이트는 앱 안에 들어 있는 `install.sh`(빌드 때 복사됨)를 `AIUSAGE_VERSION=<태그>`로 실행한다.
