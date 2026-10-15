#!/bin/bash
# 코어(BottariCore) 회귀 테스트.  ./scripts/test.sh
# bottaricli 로 목록/추출/테스트 동작을 검증한다. (7zz, xz, zstd 가 없으면 해당 항목은 건너뜀)
set -uo pipefail
cd "$(dirname "$0")/.."
swift build --product bottaricli 2>&1 | grep -E "error" && exit 1
CLI="$(swift build --show-bin-path)/bottaricli"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
cd "$W"
pass=0; fail=0
check() { if [ "$2" = "0" ]; then pass=$((pass+1)); echo "  ok   $1"; else fail=$((fail+1)); echo "  FAIL $1"; fi; }
run() { timeout 20 "$CLI" "$@"; }   # 무한 루프 방지

# ---- 픽스처
mkdir -p src/sub && echo hello > src/a.txt && head -c 100000 /dev/urandom > src/sub/rand.bin
zip -qr t.zip src && tar czf t.tar.gz src && (cd src && zip -qr -P secret ../enc.zip .)
python3 -I - "$W" <<'PY'
import tarfile, io, sys
W = sys.argv[1]
def add(t, name, data=b'', typ=None, link=None, mode=0o644):
    i = tarfile.TarInfo(name); i.mode = mode
    if typ is not None: i.type = typ
    if link: i.linkname = link
    if typ is None: i.size = len(data)
    t.addfile(i, io.BytesIO(data) if typ is None else None)
with tarfile.open('dotdot.tar', 'w') as t:
    add(t, 'ok.txt', b'ok'); add(t, 'a/../../evil.txt', b'evil')
with tarfile.open('symtrav.tar', 'w') as t:
    add(t, 'lnk', typ=tarfile.SYMTYPE, link=W + '/outside'); add(t, 'lnk/pwn.txt', b'PWNED')
with tarfile.open('dirvsfile.tar', 'w') as t:
    add(t, 'd', typ=tarfile.DIRTYPE, mode=0o755); add(t, 'd/x', b'x')
with tarfile.open('perm.tar', 'w') as t:
    add(t, 'suid', b'x', mode=0o4755); add(t, 'zero', b'z', mode=0)
PY
python3 -I - <<'PY'
import tarfile, io
def add(t, name, data=b'', mode=0o644):
    i = tarfile.TarInfo(name); i.mode = mode; i.size = len(data); t.addfile(i, io.BytesIO(data))
with tarfile.open('q.tar', 'w') as t:      # 디렉토리 엔트리 없음 (zip 의 .app 처럼)
    add(t, 'Foo.app/Contents/MacOS/Foo', b'bin', 0o555); add(t, 'ro.txt', b'ro', 0o444)
PY
: | gzip -c > empty.txt.gz
mkdir outside; printf 'hello raw\n' > one.txt; gzip -c one.txt > one.txt.gz

echo "== 기본"
run x t.zip o1 >/dev/null; run x t.tar.gz o2 >/dev/null; diff -r o1/src o2/src >/dev/null; check "zip 과 tar.gz 추출 결과 동일" $?
run x enc.zip e1 secret >/dev/null; [ "$(cat e1/a.txt)" = hello ]; check "암호 zip 추출" $?
run x one.txt.gz r1 >/dev/null; [ "$(cat r1/one.txt)" = "hello raw" ]; check "단일 .gz 추출" $?

echo "== 잘못된 암호 / 손상 (멈추면 안 됨)"
run t enc.zip wrong >/dev/null 2>&1; [ $? -eq 1 ]; check "잘못된 암호로 테스트하면 실패(무한 루프 아님)" $?
mkdir w1 && echo ORIGINAL > w1/a.txt; run x enc.zip w1 wrong >/dev/null 2>&1
[ "$(cat w1/a.txt)" = ORIGINAL ]; check "잘못된 암호 + 덮어쓰기에도 기존 파일 유지" $?
cp t.zip bad.zip; python3 -I -c "
d=bytearray(open('bad.zip','rb').read())
for i in range(300,340): d[i]^=0xFF
open('bad.zip','wb').write(d)"
run t bad.zip 2>&1 | grep -q "failures=\[\"" ; check "손상된 zip 의 CRC 오류 감지" $?

echo "== 보안"
run x dotdot.tar d1 >/dev/null; [ ! -e evil.txt ] && [ ! -e d1/evil.txt ] && [ -f d1/ok.txt ]; check ".. 경로 항목 차단" $?
run x symtrav.tar s1 >/dev/null; [ -z "$(ls outside)" ]; check "심볼릭 링크를 통한 외부 쓰기 차단" $?
run x perm.tar p1 >/dev/null; [ "$(/usr/bin/stat -f %Lp p1/suid)" = 755 ]; check "setuid 비트 제거" $?

echo "== 덮어쓰기 해제"
mkdir c1 && echo KEEPME > c1/d; NO_OVERWRITE=1 run x dirvsfile.tar c1 >/dev/null; [ "$(cat c1/d)" = KEEPME ]; check "기존 파일을 폴더로 바꾸지 않음" $?
mkdir c2 && echo OLD > c2/suid; NO_OVERWRITE=1 run x perm.tar c2 >/dev/null; [ "$(cat c2/suid)" = OLD ]; check "기존 파일 유지" $?

echo "== 격리 속성"
xattr -w com.apple.quarantine "0083;5f000000;Safari;ABCD" t.zip; run x t.zip q1 >/dev/null
xattr -p com.apple.quarantine q1/src/a.txt >/dev/null 2>&1; check "quarantine 속성 전달" $?

echo "== 격리 속성: 읽기 전용 파일 / 암묵적 상위 폴더"
xattr -w com.apple.quarantine "0083;5f000000;Safari;ABCD" q.tar; mkdir pre; mkdir pre/Foo.app; run x q.tar q2 >/dev/null; run x q.tar pre >/dev/null
xattr -p com.apple.quarantine q2/ro.txt >/dev/null 2>&1 && xattr -p com.apple.quarantine q2/Foo.app/Contents/MacOS/Foo >/dev/null 2>&1; check "0444/0555 파일에도 속성 전달" $?
xattr -p com.apple.quarantine q2/Foo.app >/dev/null 2>&1; check "암묵적으로 만들어진 .app 폴더에도 속성 전달" $?
! xattr -p com.apple.quarantine pre/Foo.app >/dev/null 2>&1; check "원래 있던 폴더에는 속성을 붙이지 않음" $?
[ "$(/usr/bin/stat -f %Lp q2/Foo.app/Contents/MacOS/Foo)" = 555 ]; check "원래 권한(0555) 유지" $?

echo "== 빈 단일 압축 파일"
run x empty.txt.gz em >/dev/null; [ -f em/empty.txt ] && [ ! -s em/empty.txt ]; check "빈 .gz 가 0바이트 파일로 풀림" $?

echo; echo "통과 $pass, 실패 $fail"; [ "$fail" -eq 0 ]
