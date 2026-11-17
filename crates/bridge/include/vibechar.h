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
bool vc_document_large(const VcDocument *document);
size_t vc_native_paragraph_budget(void);
// Returns zero when native paragraph context is needed for bidi text.
size_t vc_document_native_budget(const VcDocument *document);
// Bounded pointer-word selection in UTF-16. False for invalid or >64 KiB lines.
bool vc_document_word_range(const VcDocument *document, size_t offset, size_t *start, size_t *length);
// Logical line content length in UTF-16 units at a UTF-16 offset. SIZE_MAX if invalid.
size_t vc_document_line_length(const VcDocument *document, size_t utf16_offset);
size_t vc_document_line_count(const VcDocument *document);
// Zero-based logical line at a UTF-16 offset, or SIZE_MAX if invalid.
size_t vc_document_line_index(const VcDocument *document, size_t utf16_offset);
// Full logical line (including its ending) in UTF-16. Invalid lines fail.
bool vc_document_line_range(const VcDocument *document, size_t line, size_t *start, size_t *length);
// Logical 1-based line and display column; tab stops are four cells.
bool vc_document_position(const VcDocument *document, size_t utf16_offset, size_t *line, size_t *column);
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
typedef struct VcHistory VcHistory;
// Apply indentation (1 Tab, 2 outdent, 3 newline), returning native patches and
// mapped selection. Null means rejected input; the document is unchanged.
VcHistory *vc_document_editing(VcDocument *document, size_t start, size_t length, uint32_t action);
// Apply exactly once; own the result until free. Null means no history/invalid handle.
// UTF-16 replay-order edits are bounded to 1 MiB estimated JSON / 4,096 records.
// edits:null requests a full snapshot fallback; the history operation is already applied.
VcHistory *vc_document_history(VcDocument *document, bool redo);
size_t vc_history_json(const VcHistory *history, uint8_t *output, size_t capacity);
void vc_history_free(VcHistory *history);
bool vc_document_dirty(const VcDocument *document);
uint64_t vc_document_revision(const VcDocument *document);
void vc_document_mark_saved(VcDocument *document);
typedef struct VcMetrics VcMetrics;
VcMetrics *vc_metrics_new(void);
void vc_metrics_free(VcMetrics *metrics);
// Copy 1–1,000 UTF-16 ranges; invalid/split-surrogate ranges fail. No document mutation.
bool vc_metrics_submit(VcMetrics *metrics, const VcDocument *document,
                       const size_t *starts, const size_t *lengths, size_t count);
// Numerical metadata only; no text is serialized or persisted.
size_t vc_metrics_state(const VcMetrics *metrics, const VcDocument *document, uint8_t *output, size_t capacity);

typedef struct VcSearch VcSearch;
typedef struct VcSearchFrame VcSearchFrame;
VcSearch *vc_search_new(void);
void vc_search_free(VcSearch *search);
// flags: 1 regex, 2 case sensitive, 4 replacement enabled. No search data is persisted.
bool vc_search_submit(VcSearch *search, const VcDocument *document,
                      const uint8_t *needle, size_t needle_length,
                      const uint8_t *replacement, size_t replacement_length, uint32_t flags);
bool vc_search_busy(const VcSearch *search);
VcSearchFrame *vc_search_frame(const VcSearch *search, const VcDocument *document, uint64_t after_serial);
size_t vc_search_frame_json(const VcSearchFrame *frame, uint8_t *output, size_t capacity);
void vc_search_frame_free(VcSearchFrame *frame);
// index SIZE_MAX = all. 1 changed, 2 no-op, 0 stale/invalid. Output selection is UTF-16.
int32_t vc_search_apply(const VcSearch *search, VcDocument *document, uint64_t serial,
                        size_t index, size_t *utf16_start, size_t *utf16_length);

typedef struct VcSession VcSession;
typedef struct VcMulti VcMulti;
VcMulti *vc_multi_new(void);
void vc_multi_free(VcMulti *multi);
void vc_multi_clear(VcMulti *multi);
// Capture a UTF-16 selection (or word at caret), then match locally off the UI thread.
bool vc_multi_request(VcMulti *multi, VcDocument *document, size_t start, size_t length, bool all);
bool vc_multi_poll(VcMulti *multi, VcDocument *document);
// Adopt current Find hits (including regex/zero-width), guarded by identity/revision.
bool vc_multi_adopt(VcMulti *multi, VcDocument *document, uint64_t document_id, uint64_t revision,
                     const size_t *starts, const size_t *lengths, size_t count, size_t primary);
// Transient metadata only: selections, primary, busy, message. No source text.
size_t vc_multi_state(const VcMulti *multi, const VcDocument *document, uint8_t *output, size_t capacity);
// kind 0 isolated, 1 typing, 2 backspace, 3 delete forward, 4 newline, 5 smart paste.
// Also 6 indent/Tab, 7 outdent; 4 newline inherits each target's indentation.
// 1 changed, 2 no-op, 0 invalid/stale/limited. All targets share one undo transaction.
int32_t vc_multi_edit(VcMulti *multi, VcDocument *document, const uint8_t *text, size_t length, uint32_t kind);
// Directions: 0 left, 1 right, 2 up, 3 down, 4 line start, 5 line end, 6/7 document bounds.
bool vc_multi_move(VcMulti *multi, VcDocument *document, uint32_t direction, bool extend);
// Explicit clipboard action; returns joined nonempty selections in document order.
size_t vc_multi_copy(VcMulti *multi, const VcDocument *document, uint8_t *output, size_t capacity);
// Local text tools: commands/queries contain no source text and are never persisted.
typedef struct VcTool VcTool;
size_t vc_tool_choices(const uint8_t *query, size_t length, uint8_t *output, size_t capacity);
// Capture the immutable UTF-16 target, then prepare on a worker. Free to cancel.
VcTool *vc_tool_start(const VcDocument *document, size_t start, size_t length, uint32_t command);
void vc_tool_free(VcTool *tool);
// 0 pending, 1 ready, -1 error. Thread-confined, nonblocking.
int32_t vc_tool_poll(VcTool *tool);
size_t vc_tool_error(const VcTool *tool, uint8_t *output, size_t capacity);
// 1 changed, 2 no-op, 0 stale/invalid. Output selection is UTF-16.
int32_t vc_tool_apply(VcTool *tool, VcDocument *document, size_t *start, size_t *length);
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

// Memory-only AI proposal boundary. Capture refuses private tabs and empty/>32 KiB
// selections. No provider code runs in Rust. All ranges crossing C are UTF-16.
typedef struct VcRewrite VcRewrite;
VcRewrite *vc_rewrite_new(const VcSession *session, size_t start, size_t length);
void vc_rewrite_free(VcRewrite *value);
bool vc_rewrite_valid(const VcRewrite *value, const VcSession *session);
size_t vc_rewrite_json(const VcRewrite *value, uint8_t *output, size_t capacity);
// Protection ranges are relative to the captured selection, not the full document.
bool vc_rewrite_protect(VcRewrite *value, size_t start, size_t length);
void vc_rewrite_clear(VcRewrite *value, bool clear_protection);
bool vc_rewrite_result(VcRewrite *value, const uint8_t *text, size_t length);
// 0 rejected, 1 changed, 2 identical. Acceptance rechecks privacy/identity/revision.
int32_t vc_rewrite_apply(VcRewrite *value, VcSession *session, size_t *start, size_t *length);

#endif
