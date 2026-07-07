/*
Copyright (c) 2026 thin-edge.io contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

SPDX-License-Identifier: Apache-2.0
*/

/*
 * Payload redaction for the mosquitto message logger.
 *
 * The rules are hard-coded for thin-edge.io / Cumulocity (this is not a generic
 * tool). Two shapes are handled:
 *
 *   1. SmartREST text on a known topic - the payload is comma-delimited and the
 *      topic identifies it as sensitive. A fixed number of leading fields are
 *      kept and the remaining (secret) fields are masked. No regex needed.
 *
 *   2. JSON on any other topic - the value of a well-known sensitive key is
 *      masked wherever it appears, at any depth. The already-vendored jsmn
 *      tokeniser locates the values structurally, so a same-named *string value*
 *      (e.g. {"note":"the password is safe"}) is never touched - only keys.
 *
 * See redact.h for the public contract.
 */

#include <stdlib.h>
#include <string.h>
#include <strings.h> /* strncasecmp */
#include <stdint.h>

#include "redact.h"

#define JSMN_STATIC
#define JSMN_STRICT
#include "jsmn/jsmn.h"

/* --- SmartREST text rules -------------------------------------------------- */

/*
 * Keep the first `keep` comma-separated fields verbatim and replace every
 * remaining field with REDACT_MASK (preserving the field/comma structure).
 * Returns 1 and allocates *out when at least one field was masked, otherwise 0
 * (fewer than `keep` separators present => no trailing field to redact).
 */
static int mask_csv_fields(const char *p, uint32_t len, unsigned keep,
                           char **out, uint32_t *outlen)
{
	uint32_t i = 0;
	unsigned commas = 0;

	/* advance past the keep-th comma; i lands just after it */
	while(i < len && commas < keep){
		if(p[i] == ',') commas++;
		i++;
	}
	if(commas < keep){
		return 0; /* not enough fields - nothing sensitive to mask */
	}

	/* number of fields remaining in p[i..len) = (commas in region) + 1 */
	unsigned rem_fields = 1;
	for(uint32_t j = i; j < len; j++){
		if(p[j] == ',') rem_fields++;
	}

	size_t masklen = strlen(REDACT_MASK);
	/* prefix bytes + rem_fields masks + (rem_fields-1) commas between them */
	size_t out_sz = (size_t)i + (size_t)rem_fields * masklen + (rem_fields - 1);
	char *buf = malloc(out_sz + 1);
	if(!buf){
		return 0;
	}

	memcpy(buf, p, i);
	size_t o = i;
	for(unsigned f = 0; f < rem_fields; f++){
		if(f) buf[o++] = ',';
		memcpy(buf + o, REDACT_MASK, masklen);
		o += masklen;
	}
	buf[o] = '\0';

	*out = buf;
	*outlen = (uint32_t)o;
	return 1;
}

/* --- JSON key rules -------------------------------------------------------- */

/* Well-known sensitive key names, matched case-insensitively and in full. */
static const char *const sensitive_keys[] = {
	"password", "token", "access_token", "secret", "apikey",
};

static int key_is_sensitive(const char *s, int len)
{
	if(len <= 0) return 0;
	for(size_t k = 0; k < sizeof(sensitive_keys) / sizeof(sensitive_keys[0]); k++){
		const char *key = sensitive_keys[k];
		if((int)strlen(key) == len && strncasecmp(s, key, (size_t)len) == 0){
			return 1;
		}
	}
	return 0;
}

/* A byte span [start,end) of the original payload to replace with `rep`. */
struct span {
	int start;
	int end;
	const char *rep;
	int replen;
};

struct span_list {
	struct span *v;
	int n;
	int cap;
};

static int span_push(struct span_list *sl, int start, int end, const char *rep, int replen)
{
	if(sl->n == sl->cap){
		int newcap = sl->cap ? sl->cap * 2 : 8;
		struct span *bigger = realloc(sl->v, (size_t)newcap * sizeof(*bigger));
		if(!bigger) return 0;
		sl->v = bigger;
		sl->cap = newcap;
	}
	sl->v[sl->n].start = start;
	sl->v[sl->n].end = end;
	sl->v[sl->n].rep = rep;
	sl->v[sl->n].replen = replen;
	sl->n++;
	return 1;
}

/* Value emitted for a matched key: a JSON string. For a string value the token
 * span excludes the quotes (so we replace the inner text and keep the quotes);
 * for any other value type we replace the whole token and add quotes. */
static const char MASK_INNER[] = REDACT_MASK;          /* -> "***" via kept quotes */
static const char MASK_QUOTED[] = "\"" REDACT_MASK "\""; /* -> "***" standalone */

/* Return the token index immediately after the subtree rooted at tokens[i]. */
static int skip_subtree(const jsmntok_t *tokens, int i)
{
	int j = i + 1;
	if(tokens[i].type == JSMN_OBJECT){
		for(int m = 0; m < tokens[i].size; m++){
			j++;                       /* member key */
			j = skip_subtree(tokens, j); /* member value */
		}
	}else if(tokens[i].type == JSMN_ARRAY){
		for(int m = 0; m < tokens[i].size; m++){
			j = skip_subtree(tokens, j);
		}
	}
	return j;
}

/*
 * Walk the value at tokens[i], recording redaction spans for any sensitive key.
 * Returns the index just after this value's subtree. Because traversal is
 * depth-first left-to-right, spans are recorded in ascending, non-overlapping
 * order (a matched value is masked whole and never descended into).
 */
static int collect_spans(const char *js, const jsmntok_t *tokens, int i, struct span_list *sl)
{
	if(tokens[i].type == JSMN_OBJECT){
		int j = i + 1;
		for(int m = 0; m < tokens[i].size; m++){
			const jsmntok_t *key = &tokens[j];
			int val = j + 1;
			if(key_is_sensitive(js + key->start, key->end - key->start)){
				if(tokens[val].type == JSMN_STRING){
					span_push(sl, tokens[val].start, tokens[val].end,
						MASK_INNER, (int)sizeof(MASK_INNER) - 1);
				}else{
					span_push(sl, tokens[val].start, tokens[val].end,
						MASK_QUOTED, (int)sizeof(MASK_QUOTED) - 1);
				}
				j = skip_subtree(tokens, val);
			}else{
				j = collect_spans(js, tokens, val, sl);
			}
		}
		return j;
	}else if(tokens[i].type == JSMN_ARRAY){
		int j = i + 1;
		for(int m = 0; m < tokens[i].size; m++){
			j = collect_spans(js, tokens, j, sl);
		}
		return j;
	}
	return i + 1;
}

/* Assemble the redacted payload by splicing the recorded spans. */
static int build_output(const char *js, uint32_t len, const struct span_list *sl,
                        char **out, uint32_t *outlen)
{
	long delta = 0;
	for(int i = 0; i < sl->n; i++){
		delta += sl->v[i].replen - (sl->v[i].end - sl->v[i].start);
	}

	size_t sz = (size_t)((long)len + delta);
	char *buf = malloc(sz + 1);
	if(!buf) return 0;

	size_t o = 0;
	int prev = 0;
	for(int i = 0; i < sl->n; i++){
		int gap = sl->v[i].start - prev;
		memcpy(buf + o, js + prev, (size_t)gap);
		o += (size_t)gap;
		memcpy(buf + o, sl->v[i].rep, (size_t)sl->v[i].replen);
		o += (size_t)sl->v[i].replen;
		prev = sl->v[i].end;
	}
	memcpy(buf + o, js + prev, (size_t)((int)len - prev));
	o += (size_t)((int)len - prev);
	buf[o] = '\0';

	*out = buf;
	*outlen = (uint32_t)o;
	return 1;
}

/*
 * Redact sensitive JSON key values. Returns 1 and allocates *out when the
 * payload is a JSON object/array containing at least one sensitive key;
 * otherwise 0 (not JSON, or no key matched -> logged unchanged).
 */
static int redact_json_keys(const char *js, uint32_t len, char **out, uint32_t *outlen)
{
	jsmn_parser parser;
	jsmntok_t stack_tokens[64];
	jsmntok_t *tokens = stack_tokens;
	unsigned int cap = sizeof(stack_tokens) / sizeof(stack_tokens[0]);
	int n;

	if(len == 0) return 0;

	for(;;){
		jsmn_init(&parser);
		n = jsmn_parse(&parser, js, len, tokens, cap);
		if(n == JSMN_ERROR_NOMEM){
			unsigned int newcap = cap * 2;
			jsmntok_t *bigger = realloc(tokens == stack_tokens ? NULL : tokens,
				(size_t)newcap * sizeof(*bigger));
			if(!bigger){
				if(tokens != stack_tokens) free(tokens);
				return 0;
			}
			tokens = bigger;
			cap = newcap;
			continue;
		}
		break;
	}

	int result = 0;
	if(n >= 1 && (tokens[0].type == JSMN_OBJECT || tokens[0].type == JSMN_ARRAY)){
		struct span_list sl = {0};
		collect_spans(js, tokens, 0, &sl);
		if(sl.n > 0){
			result = build_output(js, len, &sl, out, outlen);
		}
		free(sl.v);
	}

	if(tokens != stack_tokens) free(tokens);
	return result;
}

/* --- Public entry point ---------------------------------------------------- */

int redact_payload(const char *topic, const void *payload, uint32_t payloadlen,
                   char **out, uint32_t *outlen)
{
	const char *p = (const char *)payload;

	if(payloadlen == 0){
		return 0;
	}

	/* Topic rules take precedence; these payloads are SmartREST text, not JSON. */
	if(topic){
		if(strcmp(topic, "c8y/s/dat") == 0){
			/* "71,<jwt>" -> keep the "71" template id, mask the token */
			return mask_csv_fields(p, payloadlen, 1, out, outlen);
		}
		if(strcmp(topic, "c8y/s/dcr") == 0){
			/* "70,<tenant>,<username>,<password>" -> keep id + tenant, mask the rest */
			return mask_csv_fields(p, payloadlen, 2, out, outlen);
		}
	}

	return redact_json_keys(p, payloadlen, out, outlen);
}
