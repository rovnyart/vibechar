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
bool vc_document_undo(VcDocument *document, size_t *utf16_cursor);
bool vc_document_redo(VcDocument *document, size_t *utf16_cursor);
bool vc_document_dirty(const VcDocument *document);
void vc_document_mark_saved(VcDocument *document);

#endif
