# 오픈소스 라이선스 정보

Bottari 는 아래 구성요소를 사용합니다. 소스 코드를 복사하거나 라이브러리를 앱에 포함(번들)하지 않으며,
macOS 에 기본 설치된 시스템 라이브러리를 실행 시점에 동적으로 연결합니다.

## 1. libarchive (압축 형식 읽기/풀기)

| 항목 | 내용 |
|---|---|
| 용도 | zip, 7z, rar(읽기), tar 계열, cab, iso, cpio 등 목록 읽기·압축 해제·무결성 검사 |
| 제공 방식 | macOS 시스템 라이브러리 `/usr/lib/libarchive.dylib` (Apple 이 macOS 와 함께 배포) |
| 연결 방식 | 동적 링크 (`-larchive`). 앱/DMG 에 포함되지 않음 |
| 라이선스 | New BSD License (BSD 2-Clause 계열). 일부 파일은 다른 BSD 계열 또는 퍼블릭 도메인 |
| 저작권 | Tim Kientzle 및 libarchive 기여자들 |
| 프로젝트 | https://www.libarchive.org / https://github.com/libarchive/libarchive |
| 라이선스 전문 | https://github.com/libarchive/libarchive/blob/master/COPYING |

- `Sources/CArchive/include/CArchive.h` 는 libarchive 공개 C API 의 함수·상수 이름을 직접 선언한 최소 헤더입니다.
  (macOS SDK 에 `archive.h` 가 없기 때문이며, libarchive 의 헤더 파일을 복사한 것이 아닙니다.)
- RAR 은 libarchive 자체 구현으로 읽기만 하며, RARLAB 의 unrar 코드를 사용하지 않습니다.

## 2. Apple 플랫폼 구성요소 (시스템 제공)

| 구성요소 | 설명 |
|---|---|
| Swift 런타임, AppKit, Foundation, UniformTypeIdentifiers | macOS 에 포함된 시스템 프레임워크. 별도 배포 없음 |
| SF Symbols | 툴바 아이콘을 시스템 API(`NSImage(systemSymbolName:)`)로 표시. 이미지 파일을 앱에 복사하지 않음. Apple 의 SF Symbols 사용 조건은 시스템 UI 내 사용을 전제로 하며, 이 앱은 앱 아이콘/로고에 사용하지 않음 |

## 3. 빌드·테스트에만 쓰인 도구 (배포물에 미포함)

| 도구 | 용도 |
|---|---|
| Swift Package Manager / Swift 툴체인 | 빌드. 외부 패키지 의존성 없음 (`Package.swift` 참고) |
| `iconutil`, `codesign`(ad-hoc), `hdiutil` | 아이콘/서명/DMG 생성 (macOS 기본 도구) |
| 7-Zip (`7zz`) | 개발 중 테스트용 `.7z` 파일을 만드는 데만 사용. 코드·바이너리를 가져오지 않음 |

## 4. 참고(영감) 관계

- 화면 구성은 Windows 용 7-Zip File Manager 를 참고했지만 7-Zip 의 소스 코드, 아이콘, 리소스는 사용하지 않았습니다.
  "7-Zip" 은 해당 권리자의 이름이며 Bottari 는 7-Zip 프로젝트와 무관한 별개 프로그램입니다.

## 5. Bottari 자체 라이선스

Bottari 는 MIT 라이선스로 배포됩니다. 전문은 `LICENSE` 파일을 참고하세요.
(위 구성요소는 시스템 라이브러리를 동적으로 사용하므로 Bottari 의 라이선스 선택에 제약을 주지 않습니다. 다만 앱 아이콘/문구에 서드파티 상표를 쓰지 마세요.)
