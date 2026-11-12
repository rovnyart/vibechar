#ifndef VIBECHAR_H
#define VIBECHAR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct VcDocument VcDocument;

// Handles are thread-confined. Non-null pointers must refer to valid allocations.
// Text is UTF-8, may contain NUL, and is copied before the call returns.
VcDocument *vc_document_new(const uint8_t *text, size_t length);
void vc_document_free(VcDocument *document);
size_t vc_document_length(const VcDocument *document);
// Caller owns the output buffer. Returns false if capacity is insufficient.
bool vc_document_copy(const VcDocument *document, uint8_t *output, size_t capacity);
bool vc_document_replace(VcDocument *document, size_t utf16_start, size_t utf16_length,
                         const uint8_t *replacement, size_t replacement_length);
// kind: 0 isolated, 1 typing, 2 backspace, 3 forward delete. Unknown kinds fail.
bool vc_document_edit(VcDocument *document, size_t utf16_start, size_t utf16_length,
                      const uint8_t *replacement, size_t replacement_length, uint32_t kind);
void vc_document_break_undo_group(VcDocument *document);
bool vc_document_undo(VcDocument *document, size_t *utf16_cursor);
bool vc_document_redo(VcDocument *document, size_t *utf16_cursor);
bool vc_document_dirty(const VcDocument *document);
uint64_t vc_document_revision(const VcDocument *document);
void vc_document_mark_saved(VcDocument *document);

typedef struct VcSession VcSession;
typedef struct VcSyntaxFrame VcSyntaxFrame;
void vc_session_syntax_submit(VcSession *session);
bool vc_session_syntax_busy(const VcSession *session);
// Own the returned immutable frame until vc_syntax_frame_free; null means no new paint.
VcSyntaxFrame *vc_session_syntax_frame(const VcSession *session, uint64_t after_serial);
void vc_syntax_frame_free(VcSyntaxFrame *frame);
size_t vc_syntax_frame_json(const VcSyntaxFrame *frame, uint8_t *output, size_t capacity);
size_t vc_session_language(const VcSession *session, uint8_t *output, size_t capacity);
bool vc_session_set_language(VcSession *session, const uint8_t *value, size_t length);
// Thread-safe language search; returns at most seven choices. Empty mode means Auto.
size_t vc_syntax_choices(const uint8_t *query, size_t length, uint8_t *output, size_t capacity);
VcSession *vc_session_new(void);
void vc_session_free(VcSession *session);
size_t vc_session_count(const VcSession *session);
size_t vc_session_active(const VcSession *session);
bool vc_session_select(VcSession *session, size_t index);
bool vc_session_open(VcSession *session, const uint8_t *text, size_t length,
                     const uint8_t *path, size_t path_length);
bool vc_session_open_private(VcSession *session);
bool vc_session_buffer_private(const VcSession *session, size_t index);
bool vc_session_has_private_text(const VcSession *session);
bool vc_session_needs_close_confirmation(const VcSession *session);
// 1 = shared; 2 = invalid/ordinary text; 0 = local bridge unavailable.
int32_t vc_session_share(VcSession *session);
bool vc_session_drop_active(const VcSession *session);
bool vc_session_has_drop_access(const VcSession *session);
uint64_t vc_session_drop_uses(const VcSession *session);
void vc_session_revoke_drop(VcSession *session);
void vc_session_revoke_all_drops(VcSession *session);
size_t vc_session_drop_instruction(const VcSession *session, const uint8_t *executable,
                                  size_t length, uint8_t *output, size_t capacity);
bool vc_session_close(VcSession *session, bool discard);
bool vc_session_has_unsaved(const VcSession *session);
bool vc_session_buffer_dirty(const VcSession *session, size_t index);
bool vc_session_buffer_is_file(const VcSession *session, size_t index);
// Borrowed until the next session mutation; never pass this to vc_document_free.
VcDocument *vc_session_document(VcSession *session);
// Return required UTF-8 byte length; copy only when output is non-null and fits.
size_t vc_session_label(const VcSession *session, size_t index, uint8_t *output, size_t capacity);
size_t vc_session_path(const VcSession *session, uint8_t *output, size_t capacity);
bool vc_session_set_path(VcSession *session, const uint8_t *path, size_t length);
// Call after a successful file write; ends private mode and revokes this tab's grant.
bool vc_session_complete_save(VcSession *session, const uint8_t *path, size_t length);
bool vc_session_set_selection(VcSession *session, size_t utf16_start, size_t utf16_length);
bool vc_session_selection(const VcSession *session, size_t *utf16_start, size_t *utf16_length);

// Checkpoints own immutable text snapshots and may be saved on a worker thread.
typedef struct VcCheckpoint VcCheckpoint;
VcCheckpoint *vc_session_checkpoint(const VcSession *session);
void vc_checkpoint_free(VcCheckpoint *checkpoint);
bool vc_checkpoint_save(const VcCheckpoint *checkpoint, const uint8_t *path, size_t length);
// 1 = restored, 2 = no recovery file, 0 = failure (live session is unchanged).
int32_t vc_session_restore(VcSession *session, const uint8_t *path, size_t length);

#endif
