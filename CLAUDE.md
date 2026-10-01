# AI Usage — 작업 안내

macOS 13+ 메뉴 막대 앱. SwiftPM과 Command Line Tools를 사용한다. 사용자와는 한국어로 대화한다.

## 책임과 진입점

- [앱 코드 안내](Sources/AGENTS.md): 상태·인증·파싱·화면 변경의 시작점.
- [테스트 안내](Tests/AGENTS.md): 가짜 백엔드·시계·설정으로 회귀를 재현한다.
- [스크립트 안내](scripts/AGENTS.md): 빌드·설치·문서 검증.

## 변경 명령

저장소 루트에서 실행한다. 문서만 변경하면 `make docs`; Swift 변경은 `make check`.

```sh
make docs
make check
```

`make check`는 문서 검사, Swift 빌드, 앱·격리 설치 테스트를 수행한다. 실제 앱을 설치하거나 릴리스를 게시하지 않는다.

## 의존성과 변경 영향

[아키텍처·영향표](docs/architecture.md)에서 변경할 코드와 검증을 연결한다.
[개발 기여](CONTRIBUTING.md), [검토 기준](docs/review.md), [설계 결정](docs/decisions/README.md)을 함께 읽는다.

## 반드시 지킬 규칙

- 테스트는 실제 계정·키체인·사용자 설정·네트워크를 사용하지 않는다.
- CLI 인증 정보는 읽기 전용이다. 토큰을 갱신하거나 삭제하지 않는다.
- 요청 세대, 늦은 응답 무시, 서버 재시도 대기 규칙을 보존한다.
- 사용자 문구는 한국어·영어를 함께 수정하고 변경 기록을 갱신한다.
- 배포 요청 때만 [기존 배포·운영 절차](docs/release-and-operations.md)를 순서대로 따른다.
- 점수용 빈 파일을 만들지 않는다. 실행하지 않은 검사나 AI 성과를 성공으로 기록하지 않는다.

## AI 작업 평가

[대표 과제와 측정 방식](evals/README.md)을 사용한다. 자동 문서 검사는 실제 에이전트 평가와 별개다.
