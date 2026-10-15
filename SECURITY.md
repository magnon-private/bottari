# 보안 정책 / Security Policy

## 취약점 신고 / Reporting a vulnerability

Bottari 는 압축파일을 열고 푸는 프로그램이라, 악의적으로 만든 압축파일로 인한 문제
(경로 탈출, 파일 덮어쓰기, 격리(quarantine) 속성 누락, 무한 루프/메모리 폭주, 크래시 등)가 보안 이슈가 될 수 있습니다.

**공개 이슈로 올리지 말고** GitHub 의 비공개 보안 권고로 신고해 주세요.

- <https://github.com/magnon-private/bottari/security/advisories/new>

가능하면 다음을 포함해 주세요: Bottari 버전(앱 정보창), macOS 버전, 재현에 쓴 압축파일(또는 만드는 방법), 기대한 동작과 실제 동작.
재현 파일이 악성일 수 있으니 비밀번호가 필요한 경우 함께 알려 주세요.

Please report vulnerabilities privately through the GitHub security advisory link above instead of opening a public issue.

## 지원 버전 / Supported versions

가장 최근 릴리즈만 보안 수정을 받습니다. 최신 버전은 [Releases](https://github.com/magnon-private/bottari/releases) 에서 확인할 수 있습니다.

| 버전 | 지원 |
|---|---|
| 최신 릴리즈 | ✅ |
| 이전 릴리즈 | ❌ (최신으로 업데이트해 주세요) |

## 알아 두면 좋은 점

- 릴리즈 파일은 Apple Developer 서명이 없습니다. 무결성은 릴리즈에 함께 올라가는 `.sha256` 파일로 확인할 수 있습니다.
- 압축 해제 시의 안전 규칙(위험한 경로 제외, 격리 속성 전달, 권한 처리 등)은 [README](README.md) 에 정리되어 있습니다.
