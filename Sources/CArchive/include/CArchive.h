// libarchive (macOS 내장, /usr/lib/libarchive.dylib) 의 필요한 부분만 선언한다.
#ifndef CARCHIVE_H
#define CARCHIVE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <time.h>

struct archive;
struct archive_entry;

#define ARCHIVE_EOF    1
#define ARCHIVE_OK     0
#define ARCHIVE_RETRY  (-10)
#define ARCHIVE_WARN   (-20)
#define ARCHIVE_FAILED (-25)
#define ARCHIVE_FATAL  (-30)

#define ARCHIVE_EXTRACT_OWNER             0x0001
#define ARCHIVE_EXTRACT_PERM              0x0002
#define ARCHIVE_EXTRACT_TIME              0x0004
#define ARCHIVE_EXTRACT_NO_OVERWRITE      0x0008
#define ARCHIVE_EXTRACT_UNLINK            0x0010
#define ARCHIVE_EXTRACT_SECURE_SYMLINKS   0x0100
#define ARCHIVE_EXTRACT_SECURE_NODOTDOT   0x0200
#define ARCHIVE_EXTRACT_SECURE_NOABSOLUTEPATHS 0x10000

#define ARCHIVE_AE_IFMT   0170000
#define ARCHIVE_AE_IFREG  0100000
#define ARCHIVE_AE_IFLNK  0120000
#define ARCHIVE_AE_IFDIR  0040000

// read
struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_close(struct archive *);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_add_passphrase(struct archive *, const char *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
ssize_t archive_read_data_block(struct archive *, const void **buff, size_t *len, int64_t *offset);
const char *archive_error_string(struct archive *);
const char *archive_format_name(struct archive *);
int archive_filter_count(struct archive *);
int64_t archive_filter_bytes(struct archive *, int);

// entry
const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_symlink(struct archive_entry *);
const char *archive_entry_hardlink(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
mode_t archive_entry_mode(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);
int archive_entry_is_data_encrypted(struct archive_entry *);
void archive_entry_set_pathname(struct archive_entry *, const char *);
void archive_entry_set_hardlink(struct archive_entry *, const char *);

// write to disk
struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int flags);
int archive_write_disk_set_standard_lookup(struct archive *);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data_block(struct archive *, const void *, size_t, int64_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

#endif
