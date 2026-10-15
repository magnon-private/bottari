# GEMINI.md

Bottari: macOS 용 7-Zip 스타일 압축파일 관리자. Swift 5 모드 / AppKit / macOS 12+, 외부 의존성 없음.
압축 형식 처리는 macOS 내장 `libarchive`(동적 링크). 사용자 대상 설명은 [README.md](README.md), 개발 이력 및 규칙은 [CLAUDE.md](CLAUDE.md), 라이선스는 [LICENSE](LICENSE) / [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).

## Gemini 코드 리뷰 규칙 (`"코드리뷰해줘"` 요청 시)

1. **파일 수정 엄격 금지**: 코드 리뷰 요청 시 `.gemini/code_review.md` 외의 어떤 소스 코드, 빌드 스크립트, 설정 파일도 **절대 수정하지 않는다**(읽기 전용 검토).
2. **선행 문서 확인**: 리뷰를 시작하기 전에 반드시 [CLAUDE.md](CLAUDE.md), [README.md](README.md), 그리고 이 `GEMINI.md`를 먼저 읽는다. 아래 **"수정이 필요 없다고 확인한 것"** 및 **"알려진 한계"**에 명시된 의도적 설계나 재현되지 않는 항목을 다시 지적하지 않는다.
3. **검토 범위 및 중점 항목**: 프로젝트 전체(`CArchive`, `BottariCore`, `Bottari`, `bottaricli`, `build.sh`, `scripts/`, `.github/workflows/`)를 대상으로 **보안 취약점**, **메모리 누수 및 리소스 관리**, **런타임 안정성·동시성·엣지 케이스**를 중점적으로 점검한다.
4. **결과 저장 방식**: 리뷰 결과는 `.gemini/code_review.md` 파일에 저장하되, 이전 리뷰 이력을 누적하지 않고 **이번 코드 리뷰 내용만 남도록 덮어써서(`Overwrite: true`) 작성**한다.
