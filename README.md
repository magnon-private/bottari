# Bottari

macOS 용 7-Zip 스타일 압축파일 관리자 (Swift / AppKit, macOS 12+). 압축 형식 처리는 macOS 내장 libarchive 를 사용합니다.

- zip, 7z, rar(읽기), tar, tar.gz/bz2/xz/zst, cab, iso, cpio 등 열기 (윈도우에서 만든 CP949 파일명 지원, 암호 zip 지원)
- 창에 드래그 앤 드롭 / Dock 아이콘에 드롭 / Finder "Open With" 로 열기
- 폴더 탐색, 이름·크기·수정일·속성·종류 목록, 정렬, 더블클릭으로 파일 열기, Finder 로 끌어서 꺼내기
- 압축 풀기: 현재 디렉토리 / 파일명 디렉토리 / 직접 지정, 선택 항목만 풀기, 테스트(무결성 검사)
- Finder 우클릭 ▸ 서비스(빠른 동작): Bottari로 열기, 여기에 압축 풀기, 폴더에 압축 풀기, 압축 풀기…

## 빌드 / 설치 (서명 없음, ad-hoc 만 적용)

    ./build.sh           # build/Bottari.app
    ./build.sh install   # /Applications 설치 + 서비스 등록

우클릭 메뉴가 안 보이면 시스템 설정 ▸ 키보드 ▸ 키보드 단축키 ▸ 서비스 ▸ 파일 및 폴더 에서 Bottari 항목을 켜세요.
다른 Mac 으로 복사해 "손상되었기 때문에 열 수 없음" 이 뜨면: `xattr -dr com.apple.quarantine Bottari.app`

## 라이선스

MIT — [LICENSE](LICENSE). 서드파티 정보는 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) 참고.
